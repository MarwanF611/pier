import CSensors
import SwiftUI

@main
enum PierMain {
    static func main() {
        // Claude Code runs this binary as a hook: pass the event on and quit before any UI starts.
        if CommandLine.arguments.contains(ClaudeHook.argument) {
            ClaudeHook.forwardFromStandardInput()
            exit(0)
        }
        PierApp.main()
    }
}

struct PierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(delegate.model)
        } label: {
            Image(nsImage: MenuBarGlyph.image)
                .accessibilityLabel("Pier")
        }
    }
}

/// The Pier mark reduced to one color for the menu bar: the shore, the pier hanging from it,
/// and a ripple. Drawn as a template so macOS tints it for light, dark, and highlighted states.
/// Same shape as docs/brand/pier-menubar.svg.
enum MenuBarGlyph {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            // Shore along the top and the pier hanging from it, with the lantern cut out.
            let pier = NSBezierPath()
            pier.move(to: NSPoint(x: 1, y: 1.5))
            pier.line(to: NSPoint(x: 17, y: 1.5))
            pier.line(to: NSPoint(x: 17, y: 4))
            pier.line(to: NSPoint(x: 12.3, y: 4))
            pier.quad(to: NSPoint(x: 11.4, y: 4.9), control: NSPoint(x: 11.4, y: 4))
            pier.line(to: NSPoint(x: 11.4, y: 9.3))
            pier.quad(to: NSPoint(x: 9.2, y: 11.5), control: NSPoint(x: 11.4, y: 11.5))
            pier.line(to: NSPoint(x: 8.8, y: 11.5))
            pier.quad(to: NSPoint(x: 6.6, y: 9.3), control: NSPoint(x: 6.6, y: 11.5))
            pier.line(to: NSPoint(x: 6.6, y: 4.9))
            pier.quad(to: NSPoint(x: 5.7, y: 4), control: NSPoint(x: 6.6, y: 4))
            pier.line(to: NSPoint(x: 1, y: 4))
            pier.close()
            pier.appendOval(in: NSRect(x: 7.9, y: 8.1, width: 2.2, height: 2.2))
            pier.windingRule = .evenOdd
            pier.fill()

            // A ripple ring around the tip, rising up both sides of the pier.
            let ripple = NSBezierPath()
            ripple.appendArc(withCenter: NSPoint(x: 9, y: 9.2), radius: 5.2, startAngle: 200, endAngle: -20, clockwise: true)
            ripple.lineWidth = 1.5
            ripple.lineCapStyle = .round
            ripple.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

private extension NSBezierPath {
    func quad(to end: NSPoint, control: NSPoint) {
        let start = currentPoint
        curve(to: end,
              controlPoint1: NSPoint(x: start.x + (control.x - start.x) * 2 / 3, y: start.y + (control.y - start.y) * 2 / 3),
              controlPoint2: NSPoint(x: end.x + (control.x - end.x) * 2 / 3, y: end.y + (control.y - end.y) * 2 / 3))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var panelController: DockPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--sensors") {
            pier_dump_temperature_sensors()
            exit(0)
        }
        if CommandLine.arguments.contains("--open-at-login") {
            model.setLaunchesAtLogin(true)
            print(model.launchesAtLogin ? "Pier will open at login." : "Couldn't add Pier to login items.")
            exit(model.launchesAtLogin ? 0 : 1)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task {
                await Snapshot.render(to: folder, model: model)
                exit(0)
            }
            return
        }
        model.start()
        panelController = DockPanelController(model: model)
    }

    /// Opening Pier again (Finder, Spotlight, Launchpad) brings the panel up, so its menu and
    /// Quit are reachable even when the menu bar item is hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.dock.isVisible = true
        model.dock.peek(for: 4)
        return false
    }
}

/// The menu bar item: a dependable way to show, configure, and quit Pier.
private struct MenuBarContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var dock = model.dock
        Toggle("Show Pier", isOn: $dock.isVisible)
        Toggle("Keep Open", isOn: $dock.isPinned)
        Divider()
        Button("New Note") { model.startNote() }
            .keyboardShortcut("n", modifiers: [.control, .option])
        Button(model.lectures.isActive ? "Stop Recording & Transcribe" : "Record Lecture") { model.lectures.toggle() }
            .keyboardShortcut("r", modifiers: [.control, .option])
            .disabled(model.lectures.state == .transcribing)
        Button(model.focus.isActive ? "Stop Focus" : "Focus for 25 Minutes") { model.focus.toggle(course: model.notes.selectedFolder) }
            .keyboardShortcut("t", modifiers: [.control, .option])
        Button("Take Screenshot to Shelf") { model.captureScreenshot() }
            .keyboardShortcut(KeyEquivalent("\u{F708}") /* NSF5FunctionKey */, modifiers: [.command, .shift])
        Button("Copy Text from Screen") { model.captureText() }
            .keyboardShortcut(KeyEquivalent("\u{F709}") /* NSF6FunctionKey */, modifiers: [.command, .shift])
        Button("Shuffle Wallpaper") { model.wallpapers.shuffle() }
        Divider()
        Menu(model.keepAwake.isOn ? "Keep Awake: On" : "Keep Awake") { KeepAwakeMenuItems() }
        Divider()
        DockSettingsMenuItems()
        Divider()
        Button("Quit Pier") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// The dock's own menu (right-click, or More in the panel), so settings and Quit never
/// depend on the menu bar item, which the open notch panel covers.
struct DockContextMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu(model.keepAwake.isOn ? "Keep Awake: On" : "Keep Awake") { KeepAwakeMenuItems() }
        Divider()
        DockSettingsMenuItems()
        Divider()
        Button("Quit Pier") { NSApp.terminate(nil) }
    }
}

/// Settings shared by the menu bar item and the dock's own menus.
struct DockSettingsMenuItems: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var dock = model.dock
        Picker("Position", selection: $dock.placement) {
            ForEach(DockState.Placement.allCases) { Text($0.title).tag($0) }
        }
        Toggle("Open on Hover", isOn: $dock.openOnHover)
        Menu("Show Beside Notch") {
            Toggle("Now Playing", isOn: $dock.notchShowsMusic)
            Toggle("Live Activities", isOn: $dock.notchShowsActivities)
            Divider()
            ForEach(NotchStat.allCases) { stat in
                Toggle(stat.title, isOn: Binding(get: { dock.isPinnedToNotch(stat) }, set: { _ in dock.toggleNotchPin(stat) }))
            }
        }
        Toggle("Open at Login", isOn: Binding(
            get: { model.launchesAtLogin },
            set: { model.setLaunchesAtLogin($0) }))
    }
}
