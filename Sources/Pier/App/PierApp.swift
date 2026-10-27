import CSensors
import SwiftUI

@main
struct PierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(delegate.model)
        } label: {
            Image(systemName: "dock.rectangle")
        }
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
}

/// The menu bar item: a dependable way to show, configure, and quit Pier.
private struct MenuBarContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var dock = model.dock
        Toggle("Show Pier", isOn: $dock.isVisible)
        Toggle("Keep Open", isOn: $dock.isPinned)
        Divider()
        Button("Take Screenshot to Shelf") { model.captureScreenshot() }
            .keyboardShortcut(KeyEquivalent("\u{F708}") /* NSF5FunctionKey */, modifiers: [.command, .shift])
        Button("Shuffle Wallpaper") { model.wallpapers.shuffle() }
        Divider()
        DockSettingsMenuItems()
        Divider()
        Button("Quit Pier") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Settings shared by the menu bar item and the panel's More menu.
struct DockSettingsMenuItems: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var dock = model.dock
        Picker("Position", selection: $dock.placement) {
            ForEach(DockState.Placement.allCases) { Text($0.title).tag($0) }
        }
        Toggle("Open on Hover", isOn: $dock.openOnHover)
        Toggle("Open at Login", isOn: Binding(
            get: { model.launchesAtLogin },
            set: { model.setLaunchesAtLogin($0) }))
    }
}
