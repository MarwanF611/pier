import AppKit
import Carbon.HIToolbox
import Observation
import ServiceManagement

/// A reading that can be pinned beside the notch so it shows even while Pier is closed.
enum NotchStat: String, CaseIterable, Identifiable {
    case cpu, gpu, temperature, memory, disk, battery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .temperature: "CPU Temperature"
        case .memory: "Memory"
        case .disk: "Free Disk Space"
        case .battery: "Battery"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "square.stack.3d.up"
        case .temperature: "thermometer.medium"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .battery: "battery.75percent"
        }
    }
}

/// What the open panel shows. Home has the everyday sections; the rest each get the room.
enum PanelTab: String, CaseIterable, Identifiable {
    case home, notes, clipboard, claude, shelf, wallpaper, ask

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .notes: "Notes"
        case .clipboard: "Clipboard"
        case .claude: "Claude Code"
        case .shelf: "Shelf"
        case .wallpaper: "Wallpaper"
        case .ask: "Ask Pier"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .notes: "note.text"
        case .clipboard: "list.clipboard"
        case .claude: "terminal"
        case .shelf: "tray"
        case .wallpaper: "photo.on.rectangle"
        case .ask: "sparkles"
        }
    }
}

/// UI state of the dock window itself.
@MainActor
@Observable
final class DockState {
    enum Placement: String, CaseIterable, Identifiable {
        /// Hidden in the notch until the pointer touches it.
        case notch
        /// A strip of vitals that's always visible on a screen edge.
        case left, right
        var id: String { rawValue }
        var title: String {
            switch self {
            case .notch: "Hidden in Notch"
            case .left: "Left Edge"
            case .right: "Right Edge"
            }
        }
    }

    var isExpanded = false
    /// Frame of the visible glass surface in the dock window's coordinates (top-left origin).
    var surfaceRect: CGRect = .zero
    var tab = PanelTab.home
    /// A file dragged over Pier switches to the shelf, where it will land.
    var isDropTargeted = false {
        didSet { if isDropTargeted { tab = .shelf } }
    }
    /// While set, the panel stays open even without the pointer over it.
    var peekUntil: Date?
    /// Set while typing in the panel, so it stays open with the pointer elsewhere until a
    /// click outside Pier, Escape, or saving closes it.
    var isHeldOpen = false
    /// Bumped to put the cursor in the note field.
    var noteFocusRequest = 0

    var isPinned = UserDefaults.standard.bool(forKey: "pinned") {
        didSet { UserDefaults.standard.set(isPinned, forKey: "pinned") }
    }
    var openOnHover = UserDefaults.standard.object(forKey: "openOnHover") as? Bool ?? true {
        didSet { UserDefaults.standard.set(openOnHover, forKey: "openOnHover") }
    }
    var placement = Placement(rawValue: UserDefaults.standard.string(forKey: "placement") ?? "") ?? .notch {
        didSet {
            UserDefaults.standard.set(placement.rawValue, forKey: "placement")
            isExpanded = false
            onLayoutChange?()
        }
    }
    /// Size of the camera housing at the top of the screen, or of a stand-in hover target on
    /// displays without one. Set by the window controller.
    var notchSize = CGSize(width: 200, height: 32)
    var isVisible = true {
        didSet { onLayoutChange?() }
    }

    /// Readings that stay visible beside the notch while Pier is closed, in the order pinned.
    var notchPins: [NotchStat] = (UserDefaults.standard.stringArray(forKey: "notchPins") ?? []).compactMap(NotchStat.init) {
        didSet { UserDefaults.standard.set(notchPins.map(\.rawValue), forKey: "notchPins") }
    }
    /// Show the charger, headphones, and critical readings beside the notch for a moment.
    var notchShowsActivities = UserDefaults.standard.object(forKey: "notchShowsActivities") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notchShowsActivities, forKey: "notchShowsActivities") }
    }
    /// Show artwork and a waveform beside the notch while music plays.
    var notchShowsMusic = UserDefaults.standard.object(forKey: "notchShowsMusic") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notchShowsMusic, forKey: "notchShowsMusic") }
    }

    func isPinnedToNotch(_ stat: NotchStat) -> Bool { notchPins.contains(stat) }

    func toggleNotchPin(_ stat: NotchStat) {
        if let index = notchPins.firstIndex(of: stat) { notchPins.remove(at: index) } else { notchPins.append(stat) }
    }

    @ObservationIgnored var onLayoutChange: (() -> Void)?
    /// Makes the dock window take the keyboard, set by the window controller.
    @ObservationIgnored var onRequestKeyboard: (() -> Void)?

    /// Ends a hold from typing and closes the panel, unless it's pinned open.
    func closeHeld() {
        isHeldOpen = false
        if !isPinned { isExpanded = false }
    }

    /// Opens the panel for a moment, e.g. to show a screenshot that just landed on the shelf.
    func peek(for seconds: TimeInterval = 2.5) {
        peekUntil = .now.addingTimeInterval(seconds)
        isExpanded = true
    }
}

@MainActor
@Observable
final class AppModel {
    let dock = DockState()
    let monitor = SystemMonitor()
    let music = MusicController()
    let wallpapers = WallpaperManager()
    let cleaner = StorageCleaner()
    let shelf = ShelfStore()
    let activities = LiveActivities()
    let clipboard = ClipboardHistory()
    let notes = NotesStore()
    @ObservationIgnored private(set) lazy var lectures = LectureRecorder(notes: notes, activities: activities)
    @ObservationIgnored private(set) lazy var focus = FocusTimer(activities: activities)
    let keepAwake = KeepAwake()
    @ObservationIgnored private(set) lazy var claude = ClaudeSessions(activities: activities)
    @ObservationIgnored private(set) lazy var assistant = Assistant(model: self)

    private(set) var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @ObservationIgnored private var screenshotHotKey: HotKey?
    @ObservationIgnored private var textCaptureHotKey: HotKey?
    @ObservationIgnored private var noteHotKey: HotKey?
    @ObservationIgnored private var recordHotKey: HotKey?
    @ObservationIgnored private var focusHotKey: HotKey?
    @ObservationIgnored private var isCapturing = false

    static let screenshotShortcut = "⌘⇧F5"
    static let textCaptureShortcut = "⌘⇧F6"
    static let noteShortcut = "⌃⌥N"
    static let recordShortcut = "⌃⌥R"
    static let focusShortcut = "⌃⌥T"

    func start() {
        monitor.onSample = { [weak self] in self?.activities.observe($0) }
        monitor.start()
        music.start()
        activities.start()
        clipboard.start()
        claude.start()
        // A folder prompt can't show while the panel covers it.
        notes.onSlowAccess = { [weak self] in self?.dock.closeHeld() }
        lectures.onPrompt = { [weak self] in self?.dock.closeHeld() }
        screenshotHotKey = HotKey(keyCode: kVK_F5, modifiers: cmdKey | shiftKey) { [weak self] in
            MainActor.assumeIsolated { self?.captureScreenshot() }
        }
        textCaptureHotKey = HotKey(keyCode: kVK_F6, modifiers: cmdKey | shiftKey) { [weak self] in
            MainActor.assumeIsolated { self?.captureText() }
        }
        noteHotKey = HotKey(keyCode: kVK_ANSI_N, modifiers: controlKey | optionKey) { [weak self] in
            MainActor.assumeIsolated { self?.startNote() }
        }
        recordHotKey = HotKey(keyCode: kVK_ANSI_R, modifiers: controlKey | optionKey) { [weak self] in
            MainActor.assumeIsolated { self?.lectures.toggle() }
        }
        focusHotKey = HotKey(keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey) { [weak self] in
            MainActor.assumeIsolated { self.map { $0.focus.toggle(course: $0.notes.selectedFolder) } }
        }
    }

    /// Drops the note field out of the notch, ready to type, from anywhere.
    func startNote() {
        dock.isVisible = true
        dock.tab = .notes
        dock.isExpanded = true
        dock.isHeldOpen = true
        dock.noteFocusRequest += 1
        dock.onRequestKeyboard?()
    }

    /// Lets the user drag out a region (or press Space for a window) and stashes the result on the shelf.
    func captureScreenshot() {
        let url = shelf.newFileURL(base: "Screenshot", extension: "png")
        captureRegion(to: url) {
            self.shelf.add(fileURL: url)
            self.dock.tab = .shelf
            self.dock.peek()
        }
    }

    /// Lets the user drag out a region and copies the text in it, read on this Mac.
    func captureText() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Pier Text \(UUID().uuidString).png")
        captureRegion(to: url) {
            Task {
                let text = await TextRecognizer.text(in: url)
                try? FileManager.default.removeItem(at: url)
                guard !text.isEmpty else {
                    self.activities.show(LiveActivity(symbol: "text.viewfinder", text: "No text", tint: .orange,
                                                      spoken: "No text found"))
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self.activities.show(LiveActivity(symbol: "text.viewfinder", text: "Copied", tint: .white,
                                                  spoken: "Copied text: \(text)"))
            }
        }
    }

    /// Runs the system's interactive capture; `done` runs only if something was captured.
    private func captureRegion(to url: URL, done: @escaping @MainActor () -> Void) {
        guard !isCapturing else { return }
        isCapturing = true
        if !dock.isPinned { dock.isExpanded = false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", url.path]
        process.terminationHandler = { _ in
            Task { @MainActor in
                self.isCapturing = false
                // Pressing Escape cancels the capture and writes nothing.
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                done()
            }
        }
        do { try process.run() } catch { isCapturing = false }
    }

    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Pier: launch at login change failed: \(error.localizedDescription)")
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }
}
