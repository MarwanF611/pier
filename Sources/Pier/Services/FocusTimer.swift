import AppKit
import Observation

/// A focused stretch of study for one course.
struct FocusSession: Codable, Hashable {
    var course: String
    var folderPath: String
    var start: Date
    var seconds: TimeInterval
}

/// A study timer for the selected course, with a log of the time spent on each.
@MainActor
@Observable
final class FocusTimer {
    enum State: Equatable {
        case idle
        case running(endsAt: Date)
        case paused(remaining: TimeInterval)
    }

    private(set) var state = State.idle
    private(set) var course: NoteFolder?
    private(set) var log: [FocusSession] = []

    @ObservationIgnored private let activities: LiveActivities
    @ObservationIgnored private let logURL: URL
    @ObservationIgnored private var ending: Task<Void, Never>?
    @ObservationIgnored private var sessionStart = Date.now
    /// Time actually spent focused so far, leaving out pauses.
    @ObservationIgnored private var focused: TimeInterval = 0
    @ObservationIgnored private var runningSince: Date?

    static let durations = [25, 50, 90]
    /// Shorter than this, a stopped session isn't worth logging.
    private static let minimumLogged: TimeInterval = 60

    init(activities: LiveActivities) {
        self.activities = activities
        logURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pier/focus.json")
        if let data = try? Data(contentsOf: logURL), let saved = try? JSONDecoder().decode([FocusSession].self, from: data) {
            log = saved
        }
    }

    var isActive: Bool { state != .idle }

    var remaining: TimeInterval {
        switch state {
        case .idle: 0
        case .running(let endsAt): max(0, endsAt.timeIntervalSinceNow)
        case .paused(let remaining): remaining
        }
    }

    func start(minutes: Int, course: NoteFolder) {
        if isActive { stop() }
        self.course = course
        sessionStart = .now
        focused = 0
        run(for: TimeInterval(minutes * 60))
        activities.show(LiveActivity(symbol: "timer", text: "\(minutes) min", tint: NotchEars.lantern,
                                     spoken: "Focusing on \(course.name) for \(minutes) minutes"))
    }

    func toggle(course: NoteFolder) {
        isActive ? stop() : start(minutes: Self.durations[0], course: course)
    }

    func pause() {
        guard case .running = state else { return }
        bankFocusedTime()
        ending?.cancel()
        state = .paused(remaining: remaining)
    }

    func resume() {
        guard case .paused(let remaining) = state else { return }
        run(for: remaining)
    }

    /// Ends early, keeping the time spent so far.
    func stop() {
        guard isActive else { return }
        bankFocusedTime()
        ending?.cancel()
        state = .idle
        record()
    }

    /// Time logged per course since Monday, most first.
    func thisWeek(now: Date = .now) -> [(course: String, seconds: TimeInterval)] {
        guard let week = Calendar.current.dateInterval(of: .weekOfYear, for: now) else { return [] }
        var totals: [String: TimeInterval] = [:]
        for session in log where week.contains(session.start) { totals[session.course, default: 0] += session.seconds }
        if isActive, let course {
            totals[course.name, default: 0] += focused + (runningSince.map { now.timeIntervalSince($0) } ?? 0)
        }
        return totals.map { ($0.key, $0.value) }.filter { $0.1 >= 60 }.sorted { $0.1 > $1.1 }
    }

    private func run(for seconds: TimeInterval) {
        let endsAt = Date.now.addingTimeInterval(seconds)
        state = .running(endsAt: endsAt)
        runningSince = .now
        ending?.cancel()
        ending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    private func finish() {
        bankFocusedTime()
        state = .idle
        record()
        NSSound(named: "Glass")?.play()
        activities.show(LiveActivity(symbol: "checkmark.circle.fill", text: "Focus done", tint: .green,
                                     spoken: "Focus session for \(course?.name ?? "your course") is done. Time for a break."), for: 6)
    }

    private func bankFocusedTime() {
        if let since = runningSince { focused += Date.now.timeIntervalSince(since) }
        runningSince = nil
    }

    private func record() {
        guard let course, focused >= Self.minimumLogged else { return }
        log.append(FocusSession(course: course.name, folderPath: course.url.path, start: sessionStart, seconds: focused))
        // A year of sessions is plenty for weekly totals.
        let cutoff = Date.now.addingTimeInterval(-366 * 86_400)
        log.removeAll { $0.start < cutoff }
        if let data = try? JSONEncoder().encode(log) {
            try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: logURL, options: .atomic)
        }
        focused = 0
    }
}
