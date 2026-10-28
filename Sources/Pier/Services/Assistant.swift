import AppKit
import FoundationModels
import Observation

/// Ask Pier: a conversation with Apple's on-device language model, which answers from Pier's
/// own readings and acts through Pier's own controls. Nothing leaves the Mac.
@MainActor
@Observable
final class Assistant {
    struct Turn: Identifiable {
        let id = UUID()
        var question: String
        var answer = ""
        var failed = false
    }

    private(set) var turns: [Turn] = []
    /// The question being typed, kept here so it survives the panel closing.
    var draft = ""
    private(set) var isResponding = false
    private(set) var availability = SystemLanguageModel.default.availability

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private var session: LanguageModelSession?

    /// The on-device model has a small context window, so instructions and tool descriptions
    /// stay short and each tool returns a compact summary.
    private static let instructions = """
        You are Pier, an assistant in the notch of the user's Mac. You run entirely on this Mac.
        Use your tools to read the Mac's state and to act: system status, music, wallpaper, \
        shelf, and storage. Never guess a reading; call a tool.
        You can't delete files. For cleaning up, say the user can review and confirm it in \
        Pier's Storage section.
        Answer in one to three short sentences, in the language the user writes in.
        """

    init(model: AppModel) {
        self.model = model
    }

    func refreshAvailability() {
        availability = SystemLanguageModel.default.availability
    }

    func ask(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isResponding else { return }
        refreshAvailability()
        guard availability == .available else { return }

        draft = ""
        turns.append(Turn(question: question))
        let index = turns.count - 1
        isResponding = true
        Task {
            defer { isResponding = false }
            do {
                try await respond(to: question, into: index)
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                // The conversation outgrew the model; start over with only this question.
                session = nil
                do { try await respond(to: question, into: index) } catch { fail(index, error) }
            } catch {
                fail(index, error)
            }
            if !model.dock.isExpanded {
                model.activities.show(LiveActivity(symbol: "sparkles", text: "Answered", tint: NotchEars.lantern,
                                                   spoken: "Pier answered: \(turns[index].answer)"))
            }
        }
    }

    /// Forgets the conversation, so the next question starts fresh.
    func reset() {
        guard !isResponding else { return }
        turns = []
        session = nil
    }

    func openSettings() {
        let pane = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!
        if !NSWorkspace.shared.open(pane) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    private func respond(to question: String, into index: Int) async throws {
        let session = session ?? LanguageModelSession(tools: [
            SystemStatusTool(model: model), MusicTool(model: model), WallpaperTool(model: model),
            ShelfTool(model: model), StorageTool(model: model),
        ], instructions: Self.instructions)
        self.session = session
        for try await snapshot in session.streamResponse(to: question) {
            turns[index].answer = snapshot.content
        }
    }

    private func fail(_ index: Int, _ error: Error) {
        turns[index].failed = true
        turns[index].answer = switch error {
        case LanguageModelSession.GenerationError.guardrailViolation, LanguageModelSession.GenerationError.refusal:
            "I can't help with that one."
        case LanguageModelSession.GenerationError.unsupportedLanguageOrLocale:
            "I don't understand that language yet."
        case LanguageModelSession.GenerationError.assetsUnavailable:
            "Apple's model isn't ready yet. Try again in a moment."
        case LanguageModelSession.GenerationError.rateLimited, LanguageModelSession.GenerationError.concurrentRequests:
            "I'm busy. Try again in a moment."
        default:
            "Something went wrong: \(error.localizedDescription)"
        }
    }
}

// MARK: - Tools

/// Readings plus the processes behind them, so "why is my Mac slow?" has an answer.
private struct SystemStatusTool: Tool {
    let model: AppModel
    let name = "systemStatus"
    let description = "Current CPU, GPU, memory, temperature, disk, battery, and the apps using the most CPU and memory."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        let processes = TopProcesses.read()
        let s = await model.monitor.snapshot
        var lines = [
            "CPU \(s.cpuUsage.percent)" + (s.gpuUsage.map { ", GPU \($0.percent)" } ?? ""),
            "Memory \(s.memoryUsage.percent) used (\(s.memoryAvailable.memoryBytes) available), swap \(s.swapUsed.memoryBytes)",
            "Disk \(s.diskFree.bytes) free of \(s.diskTotal.bytes)",
        ]
        if let celsius = s.cpuTemperature { lines.append("CPU temperature \(Int(celsius.rounded())) °C") }
        if let level = s.batteryLevel { lines.append("Battery \(level.percent)\(s.isPluggedIn ? ", plugged in" : "")") }
        lines.append("Most CPU (100% = one core): " + processes.byCPU.joined(separator: ", "))
        lines.append("Most memory: " + processes.byMemory.joined(separator: ", "))
        return lines.joined(separator: "\n")
    }
}

private struct MusicTool: Tool {
    let model: AppModel
    let name = "music"
    let description = "Play, pause, or skip in Music or Spotify, or tell what is playing."

    @Generable
    enum Action {
        case status, play, pause, next, previous
    }

    @Generable
    struct Arguments {
        var action: Action
    }

    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            let music = model.music
            let playing = music.nowPlaying
            switch arguments.action {
            case .status: break
            case .play: if playing?.isPlaying != true { music.playPause() }
            case .pause: if playing?.isPlaying == true { music.playPause() }
            case .next: music.nextTrack()
            case .previous: music.previousTrack()
            }
            guard let playing else { return "Nothing is playing; open Music or Spotify first." }
            let done = arguments.action == .status ? "" : "Done. "
            return done + "\(playing.isPlaying ? "Playing" : "Paused"): \(playing.title) by \(playing.artist) in \(playing.player.displayName)."
        }
    }
}

private struct WallpaperTool: Tool {
    let model: AppModel
    let name = "wallpaper"
    let description = "Shuffle the desktop wallpaper, set one by name, or list the names."

    @Generable
    enum Action {
        case shuffle, set, list
    }

    @Generable
    struct Arguments {
        var action: Action
        @Guide(description: "Wallpaper name, only for set")
        var name: String?
    }

    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            let wallpapers = model.wallpapers
            switch arguments.action {
            case .shuffle:
                wallpapers.shuffle()
                return "Changed the wallpaper to \(wallpapers.current?.deletingPathExtension().lastPathComponent ?? "a new one")."
            case .set:
                let name = arguments.name?.lowercased() ?? ""
                guard !name.isEmpty, let match = wallpapers.wallpapers.first(where: { $0.name.lowercased().contains(name) }) else {
                    return "No wallpaper matches that name."
                }
                wallpapers.apply(match)
                return "Changed the wallpaper to \(match.name)."
            case .list:
                return "Wallpapers: " + wallpapers.wallpapers.prefix(30).map(\.name).joined(separator: ", ")
            }
        }
    }
}

private struct ShelfTool: Tool {
    let model: AppModel
    let name = "shelf"
    let description = "List the files on Pier's shelf, or let the user take a screenshot onto it."

    @Generable
    enum Action {
        case list, screenshot
    }

    @Generable
    struct Arguments {
        var action: Action
    }

    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            switch arguments.action {
            case .list:
                let items = model.shelf.items
                return items.isEmpty ? "The shelf is empty." : "On the shelf: " + items.prefix(20).map(\.name).joined(separator: ", ")
            case .screenshot:
                model.captureScreenshot()
                return "The user can now drag out an area to capture, or press Escape to cancel."
            }
        }
    }
}

/// Finds what could be cleaned, but leaves cleaning itself to the user's own click.
private struct StorageTool: Tool {
    let model: AppModel
    let name = "storage"
    let description = "Find caches, logs, and other files that could be cleaned up, with their sizes."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        let cleaner = await model.cleaner
        if await cleaner.phase != .ready {
            await cleaner.scan()
            // A scan of large caches takes a while; give up waiting rather than hang the answer.
            for _ in 0..<40 {
                guard await cleaner.phase == .scanning else { break }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        guard await cleaner.phase == .ready else {
            return "Still scanning; the results will appear in Pier's Storage section."
        }
        let found = await cleaner.categories.map { "\($0.title) \($0.size?.bytes ?? "size unknown")" }
        return found.isEmpty ? "Nothing to clean." : "Could clean: " + found.joined(separator: ", ")
            + ". The user reviews and confirms this in the Storage section."
    }
}

/// The busiest processes by CPU and by memory, as `ps` reports them.
private enum TopProcesses {
    static func read(count: Int = 4) -> (byCPU: [String], byMemory: [String]) {
        let rows = ps(["-Aceo", "pcpu=,rss=,comm="])
        let byCPU = rows.sorted { $0.cpu > $1.cpu }.prefix(count).map { "\($0.name) \(Int($0.cpu.rounded()))%" }
        let byMemory = rows.sorted { $0.memory > $1.memory }.prefix(count).map { "\($0.name) \($0.memory.bytes)" }
        return (byCPU, byMemory)
    }

    private static func ps(_ arguments: [String]) -> [(cpu: Double, memory: Int64, name: String)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return [] }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let cpu = Double(fields[0].replacingOccurrences(of: ",", with: ".")),
                  let kilobytes = Int64(fields[1]) else { return nil }
            return (cpu, kilobytes * 1024, String(fields[2]))
        }
    }
}
