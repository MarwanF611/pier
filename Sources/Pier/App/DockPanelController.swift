import AppKit
import SwiftUI

/// A borderless panel that floats above other windows without stealing focus.
private final class DockPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Clicks act immediately instead of first focusing the panel.
private final class DockHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the dock window: places it on the screen edge and opens or closes it as the pointer
/// comes and goes. The window spans the full edge but ignores the mouse outside the visible
/// glass, so the rest of that strip of screen stays clickable.
@MainActor
final class DockPanelController {
    private let model: AppModel
    private let panel: DockPanel
    private var pointerTimer: Timer?
    private var hoverStartedAt: Date?
    private var leftAt: Date?

    private static let windowWidth: CGFloat = 420
    private static let notchWindowWidth: CGFloat = 860
    private static let notchWindowHeight: CGFloat = 640
    private static let openDelay: TimeInterval = 0.22
    private static let closeDelay: TimeInterval = 0.45

    init(model: AppModel) {
        self.model = model
        panel = DockPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true

        // The panel never becomes key, so without this every control would draw in its
        // dimmed inactive-window state.
        let root = DockRootView()
            .environment(model)
            .environment(\.controlActiveState, .key)
        let hostingView = DockHostingView(rootView: root)
        hostingView.sizingOptions = []
        panel.contentView = hostingView

        model.dock.onLayoutChange = { [weak self] in self?.layout() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }

        layout()
        if let folder = ProcessInfo.processInfo.environment["PIER_SELFSHOT"] {
            Task { [panel] in
                try? await Task.sleep(for: .seconds(3))
                await Snapshot.captureLiveWindow(panel, model: model, to: URL(fileURLWithPath: folder))
            }
        }
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackPointer() }
        }
    }

    private func layout() {
        let dock = model.dock
        guard dock.isVisible else { panel.orderOut(nil); return }

        switch dock.placement {
        case .notch:
            // Prefer the built-in display, which is the one with the notch.
            guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first else { return }
            if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                dock.notchSize = CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
            } else {
                // No notch: an invisible hover target in the middle of the menu bar.
                dock.notchSize = CGSize(width: 200, height: max(24, screen.frame.maxY - screen.visibleFrame.maxY))
            }
            let size = CGSize(width: Self.notchWindowWidth, height: min(Self.notchWindowHeight, screen.frame.height - 40))
            // Above the menu bar, so the panel can grow out of the notch.
            panel.level = .statusBar
            panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                                  width: size.width, height: size.height), display: true)

        case .left, .right:
            guard let screen = NSScreen.screens.first else { return }
            let visible = screen.visibleFrame
            let x = dock.placement == .right ? visible.maxX - Self.windowWidth : visible.minX
            panel.level = .floating
            panel.setFrame(NSRect(x: x, y: visible.minY, width: Self.windowWidth, height: visible.height), display: true)
        }
        panel.orderFrontRegardless()
    }

    /// The visible glass surface in screen coordinates.
    private var surfaceOnScreen: NSRect {
        let rect = model.dock.surfaceRect
        let frame = panel.frame
        return NSRect(x: frame.minX + rect.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    private func trackPointer() {
        let dock = model.dock
        guard dock.isVisible else { return }

        // Typing into Ask Pier makes the panel key. Once it closes, hand the keyboard back to
        // the app in front, so keystrokes don't keep landing in a panel that's gone.
        if !dock.isExpanded, panel.isKeyWindow {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }

        let inside = surfaceOnScreen.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !inside
        let now = Date.now

        if inside {
            leftAt = nil
            dock.peekUntil = nil
            // A drag (e.g. a file from Finder) opens it right away so the shelf is reachable.
            let dragging = NSEvent.pressedMouseButtons != 0
            if !dock.isExpanded, dock.openOnHover || dragging {
                if let started = hoverStartedAt {
                    if now.timeIntervalSince(started) >= (dragging ? 0.1 : Self.openDelay) { dock.isExpanded = true }
                } else {
                    hoverStartedAt = now
                }
            }
            return
        }

        hoverStartedAt = nil
        // Close even while a cleanup runs: it carries on in the model, and it may be waiting
        // on a system permission prompt that the open panel would cover.
        guard dock.isExpanded, !dock.isPinned else { leftAt = nil; return }
        if let peek = dock.peekUntil, peek > now { return }
        if let left = leftAt {
            if now.timeIntervalSince(left) >= Self.closeDelay {
                dock.isExpanded = false
                dock.peekUntil = nil
                leftAt = nil
                model.shelf.pruneMissing()
            }
        } else {
            leftAt = now
        }
    }
}
