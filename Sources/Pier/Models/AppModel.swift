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
    var isDropTargeted = false
    /// While set, the panel stays open even without the pointer over it.
    var peekUntil: Date?

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
    var screenHasNotch = false
    var isVisible = true {
        didSet { onLayoutChange?() }
    }

    /// Readings that stay visible beside the notch while Pier is closed, in the order pinned.
    var notchPins: [NotchStat] = (UserDefaults.standard.stringArray(forKey: "notchPins") ?? []).compactMap(NotchStat.init) {
        didSet { UserDefaults.standard.set(notchPins.map(\.rawValue), forKey: "notchPins") }
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

    private(set) var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @ObservationIgnored private var screenshotHotKey: HotKey?
    @ObservationIgnored private var isCapturing = false

    static let screenshotShortcut = "⌘⇧F5"

    func start() {
        monitor.start()
        music.start()
        screenshotHotKey = HotKey(keyCode: kVK_F5, modifiers: cmdKey | shiftKey) { [weak self] in
            MainActor.assumeIsolated { self?.captureScreenshot() }
        }
    }

    /// Lets the user drag out a region (or press Space for a window) and stashes the result on the shelf.
    func captureScreenshot() {
        guard !isCapturing else { return }
        isCapturing = true
        if !dock.isPinned { dock.isExpanded = false }

        let url = shelf.newFileURL(base: "Screenshot", extension: "png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", url.path]
        process.terminationHandler = { _ in
            Task { @MainActor in
                self.isCapturing = false
                // Pressing Escape cancels the capture and writes nothing.
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                self.shelf.add(fileURL: url)
                self.dock.peek()
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
