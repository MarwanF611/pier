import AppKit
import Observation
import SwiftUI

/// Claude Code runs Pier's own binary as a hook (`Pier --claude-hook`) for each event in a
/// session. That process reads the event Claude Code writes to standard input, hands it to the
/// running Pier as a distributed notification, and quits before any UI starts.
enum ClaudeHook {
    static let argument = "--claude-hook"
    static let notification = Notification.Name("com.marwanfikri.pier.claude")

    /// The events Pier listens to, and the matcher each needs.
    static let events: [(name: String, matcher: String?)] = [
        ("UserPromptSubmit", nil), ("PostToolUse", "*"), ("Notification", nil), ("Stop", nil), ("SessionEnd", nil),
    ]

    static func forwardFromStandardInput() {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let event = json["hook_event_name"] as? String else { return }
        var info: [String: String] = ["event": event]
        for key in ["session_id", "cwd", "message", "notification_type"] {
            if let value = json[key] as? String { info[key] = value }
        }
        DistributedNotificationCenter.default().postNotificationName(notification, object: nil, userInfo: info,
                                                                     deliverImmediately: true)
    }

    // MARK: - Hooks in Claude Code's settings

    static let settingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")

    /// Exits cleanly when Pier has been moved or deleted, so Claude Code never shows a hook error.
    private static var command: String {
        let path = Bundle.main.executablePath ?? "/Applications/Pier.app/Contents/MacOS/Pier"
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "[ -x \(quoted) ] && \(quoted) \(argument) || true"
    }

    private static func isPier(_ group: Any) -> Bool {
        let hooks = (group as? [String: Any])?["hooks"] as? [[String: Any]] ?? []
        return hooks.contains { ($0["command"] as? String)?.contains(argument) == true }
    }

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static var isConnected: Bool {
        guard let hooks = readSettings()?["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in (hooks[event.name] as? [Any])?.contains(where: isPier) == true }
    }

    /// Adds Pier's hooks next to any the user already has. Returns false if the settings file
    /// couldn't be read as JSON, in which case it is left alone.
    @discardableResult
    static func connect() -> Bool {
        update { hooks in
            for event in events {
                var groups = (hooks[event.name] as? [Any] ?? []).filter { !isPier($0) }
                var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 5]]]
                if let matcher = event.matcher { group["matcher"] = matcher }
                groups.append(group)
                hooks[event.name] = groups
            }
        }
    }

    @discardableResult
    static func disconnect() -> Bool {
        update { hooks in
            for (name, value) in hooks {
                guard let groups = value as? [Any] else { continue }
                let kept = groups.filter { !isPier($0) }
                hooks[name] = kept.isEmpty ? nil : kept
            }
        }
    }

    private static func update(_ change: (inout [String: Any]) -> Void) -> Bool {
        guard var settings = readSettings() else { return false }
        // Keep a copy of the file as it was before Pier first touched it.
        let backup = settingsURL.appendingPathExtension("before-pier")
        if FileManager.default.fileExists(atPath: settingsURL.path), !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: settingsURL, to: backup)
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        change(&hooks)
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        guard let data = try? JSONSerialization.data(withJSONObject: settings,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return false }
        try? FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: settingsURL, options: .atomic)) != nil
    }
}

struct ClaudeSession: Identifiable {
    enum State: Equatable {
        case working
        case needsYou(String)
        case done
        /// No word from it for a while: interrupted, or left open.
        case idle
    }

    let id: String
    var folder: URL?
    var state: State
    /// When the current or last turn started.
    var turnStartedAt: Date
    var lastEventAt: Date
    var turnDuration: TimeInterval?

    var name: String { folder?.lastPathComponent ?? "Claude" }

    var isWaitingOnYou: Bool {
        if case .needsYou = state { return true }
        return false
    }

    var isActive: Bool { state == .working || isWaitingOnYou }
}

/// Every Claude Code session Pier has heard from, and the live activities they raise.
@MainActor
@Observable
final class ClaudeSessions {
    private(set) var sessions: [ClaudeSession] = []
    private(set) var isConnected = ClaudeHook.isConnected
    /// Set when connecting fails, e.g. because the settings file isn't valid JSON.
    private(set) var connectionError: String?

    var playsSound = UserDefaults.standard.object(forKey: "claudePlaysSound") as? Bool ?? true {
        didSet { UserDefaults.standard.set(playsSound, forKey: "claudePlaysSound") }
    }

    @ObservationIgnored private let activities: LiveActivities
    @ObservationIgnored private var pruneTimer: Timer?

    /// A turn this long has probably sent you elsewhere, so its end is worth a sound.
    private static let soundAfter: TimeInterval = 30
    private static let idleAfter: TimeInterval = 15 * 60
    private static let forgetAfter: TimeInterval = 60 * 60
    static let tint = Color(red: 0.85, green: 0.47, blue: 0.34)

    init(activities: LiveActivities) {
        self.activities = activities
    }

    func start() {
        DistributedNotificationCenter.default().addObserver(forName: ClaudeHook.notification, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo as? [String: String] ?? [:]
            MainActor.assumeIsolated { self?.handle(info) }
        }
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prune() }
        }
    }

    /// The session most worth showing beside the notch: one that needs you, else the longest at work.
    var featured: ClaudeSession? {
        sessions.first(where: \.isWaitingOnYou)
            ?? sessions.filter { $0.state == .working }.min { $0.turnStartedAt < $1.turnStartedAt }
    }

    func connect() {
        connectionError = ClaudeHook.connect() ? nil : "Couldn't read ~/.claude/settings.json, so Pier left it alone."
        isConnected = ClaudeHook.isConnected
    }

    func disconnect() {
        ClaudeHook.disconnect()
        isConnected = ClaudeHook.isConnected
        sessions = []
    }

    func forget(_ session: ClaudeSession) {
        sessions.removeAll { $0.id == session.id }
    }

    func handle(_ info: [String: String]) {
        guard let event = info["event"] else { return }
        let id = info["session_id"] ?? info["cwd"] ?? "claude"
        let now = Date.now
        if event == "SessionEnd" { sessions.removeAll { $0.id == id }; return }

        var session = sessions.first { $0.id == id }
            ?? ClaudeSession(id: id, folder: info["cwd"].map { URL(fileURLWithPath: $0) }, state: .idle,
                             turnStartedAt: now, lastEventAt: now)
        session.lastEventAt = now
        if let cwd = info["cwd"] { session.folder = URL(fileURLWithPath: cwd) }

        switch event {
        case "UserPromptSubmit":
            session.state = .working
            session.turnStartedAt = now
            session.turnDuration = nil
        case "PostToolUse":
            // A tool ran, so a permission question, if any, has been answered.
            if session.state == .done || session.state == .idle { session.turnStartedAt = now }
            session.state = .working
        case "Notification":
            let message = info["message"] ?? "Claude needs you"
            // Waiting at the prompt after a finished turn is not news.
            guard info["notification_type"] != "idle_prompt", !message.localizedCaseInsensitiveContains("waiting for your input")
            else { break }
            session.state = .needsYou(message)
            activities.show(LiveActivity(symbol: "hand.raised.fill", text: "\(session.name) needs you", tint: .orange,
                                         spoken: "Claude in \(session.name): \(message)"), for: 6)
        case "Stop":
            let duration = now.timeIntervalSince(session.turnStartedAt)
            session.state = .done
            session.turnDuration = duration
            activities.show(LiveActivity(symbol: "checkmark.circle.fill", text: "\(session.name) done", tint: .green,
                                         spoken: "Claude finished in \(session.name)"), for: 6)
            if playsSound, duration >= Self.soundAfter { NSSound(named: "Glass")?.play() }
        default:
            break
        }

        if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index] = session } else { sessions.insert(session, at: 0) }
    }

    private func prune() {
        let now = Date.now
        sessions.removeAll { now.timeIntervalSince($0.lastEventAt) > Self.forgetAfter }
        for index in sessions.indices where sessions[index].isActive && now.timeIntervalSince(sessions[index].lastEventAt) > Self.idleAfter {
            sessions[index].state = .idle
        }
    }
}
