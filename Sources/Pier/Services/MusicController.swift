import AppKit
import Observation

/// A music app Pier can drive over Apple Events.
enum MusicPlayer: String, CaseIterable, Identifiable {
    case music = "com.apple.Music"
    case spotify = "com.spotify.client"

    var id: String { rawValue }
    var displayName: String { self == .music ? "Music" : "Spotify" }
    var scriptName: String { self == .music ? "Music" : "Spotify" }

    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: rawValue).isEmpty }
    var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue) != nil }
    var icon: NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}

struct NowPlaying: Equatable {
    var player: MusicPlayer
    var isPlaying: Bool
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var position: TimeInterval
    var trackID: String
    var artworkURL: URL?
    /// When `position` was read, so the progress bar can advance between polls.
    var readAt: Date

    func position(at date: Date) -> TimeInterval {
        guard isPlaying else { return position }
        return min(duration, position + date.timeIntervalSince(readAt))
    }
}

@MainActor
@Observable
final class MusicController {
    private(set) var nowPlaying: NowPlaying?
    private(set) var artwork: NSImage?
    /// Set when macOS refused Pier permission to control a player.
    private(set) var permissionDenied: MusicPlayer?

    private let runner = AppleScriptRunner()
    private var timer: Timer?
    private var artworkTrackID: String?

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer?.tolerance = 0.4
    }

    func playPause() { send("playpause", optimisticToggle: true) }
    func nextTrack() { send("next track") }
    func previousTrack() { send("previous track") }

    func open(_ player: MusicPlayer) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.rawValue) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    private func send(_ command: String, optimisticToggle: Bool = false) {
        guard let player = nowPlaying?.player ?? MusicPlayer.allCases.first(where: \.isRunning) else { return }
        if optimisticToggle, var playing = nowPlaying {
            playing.position = playing.position(at: .now)
            playing.readAt = .now
            playing.isPlaying.toggle()
            nowPlaying = playing
        }
        let source = "tell application \"\(player.scriptName)\" to \(command)"
        Task {
            _ = await runner.run(source)
            try? await Task.sleep(for: .milliseconds(350))
            poll()
        }
    }

    private func poll() {
        // Asking a player that isn't running would launch it, so check first.
        let running = MusicPlayer.allCases.filter(\.isRunning)
        guard !running.isEmpty else {
            nowPlaying = nil
            artwork = nil
            artworkTrackID = nil
            return
        }

        Task {
            var states: [NowPlaying] = []
            for player in running {
                let result = await runner.run(Self.statusScript(for: player))
                switch result {
                case .success(let text):
                    if let state = Self.parse(text, player: player) { states.append(state) }
                    if permissionDenied == player { permissionDenied = nil }
                case .failure(let code):
                    if code == -1743 { permissionDenied = player }
                }
            }
            // Prefer whatever is actually playing; otherwise the most recently paused track.
            let current = states.first(where: \.isPlaying) ?? states.first
            nowPlaying = current
            await updateArtwork(for: current)
        }
    }

    private func updateArtwork(for state: NowPlaying?) async {
        guard let state else { artwork = nil; artworkTrackID = nil; return }
        guard state.trackID != artworkTrackID else { return }
        artworkTrackID = state.trackID
        artwork = nil

        switch state.player {
        case .music:
            let data = await runner.data("tell application \"Music\" to get raw data of artwork 1 of current track")
            if artworkTrackID == state.trackID { artwork = data.flatMap(NSImage.init(data:)) }
        case .spotify:
            // Only fetch cover art over HTTPS; never file:// or plain HTTP URLs.
            guard let url = state.artworkURL, url.scheme == "https",
                  let (data, _) = try? await URLSession.shared.data(from: url) else { return }
            if artworkTrackID == state.trackID { artwork = NSImage(data: data) }
        }
    }

    private static let separator = "\u{1F}"

    private static func statusScript(for player: MusicPlayer) -> String {
        let durationExpression = player == .spotify ? "((duration of t) / 1000)" : "(duration of t)"
        let idExpression = player == .spotify ? "(id of t)" : "(persistent ID of t)"
        let artworkExpression = player == .spotify ? "(artwork url of t)" : "\"\""
        return """
        tell application "\(player.scriptName)"
            set sep to character id 31
            set s to player state as string
            if s is "stopped" then return s
            set t to current track
            return s & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & \(durationExpression) & sep & (player position) & sep & \(idExpression) & sep & \(artworkExpression)
        end tell
        """
    }

    private static func parse(_ text: String, player: MusicPlayer) -> NowPlaying? {
        let fields = text.components(separatedBy: separator)
        guard fields.count >= 8 else { return nil }
        // AppleScript formats reals with the user's locale, so "201,5" is possible.
        func number(_ string: String) -> Double { Double(string.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        return NowPlaying(
            player: player,
            isPlaying: fields[0] == "playing",
            title: fields[1],
            artist: fields[2],
            album: fields[3],
            duration: number(fields[4]),
            position: number(fields[5]),
            trackID: fields[6],
            artworkURL: URL(string: fields[7]),
            readAt: .now
        )
    }
}

/// Runs AppleScript one script at a time off the main thread.
private actor AppleScriptRunner {
    enum Result { case success(String), failure(Int) }

    func run(_ source: String) -> Result {
        var error: NSDictionary?
        let descriptor = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { return .failure(error[NSAppleScript.errorNumber] as? Int ?? -1) }
        return .success(descriptor?.stringValue ?? "")
    }

    func data(_ source: String) -> Data? {
        var error: NSDictionary?
        let descriptor = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? descriptor?.data : nil
    }
}
