import AppKit
import SwiftUI

/// Development aid: `Pier --snapshot <folder>` renders the strip and the open panel over the
/// current wallpaper, in light and dark, and writes PNGs. No screen recording permission needed.
@MainActor
enum Snapshot {
    static func render(to folder: URL, model: AppModel) async {
        model.start()
        try? await Task.sleep(for: .seconds(3.5)) // let stats, music, and thumbnails arrive
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // The menu bar glyph at 8x, black on white.
        let glyph = NSImage(size: NSSize(width: 144, height: 144), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            MenuBarGlyph.image.draw(in: rect)
            return true
        }
        if let tiff = glyph.tiffRepresentation {
            try? NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])?
                .write(to: folder.appendingPathComponent("menubar-glyph.png"))
        }

        let wallpaper = NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
            .flatMap { WallpaperManager.downsample($0, maxPixel: 1600) }

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for expanded in [false, true] {
                model.dock.isExpanded = expanded
                let view = DockRootView()
                    .environment(model)
                    .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
                    .frame(width: 520, height: 900)
                    .background {
                        if let wallpaper { Image(nsImage: wallpaper).resizable().aspectRatio(contentMode: .fill) }
                    }
                    .clipped()

                let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 520, height: 900),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                let host = NSHostingView(rootView: view)
                window.contentView = host
                window.orderFrontRegardless()
                try? await Task.sleep(for: .seconds(1.2))

                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                let name = "\(expanded ? "panel" : "strip")-\(appearance == .darkAqua ? "dark" : "light").png"
                try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name))
                window.orderOut(nil)
            }
        }
    }

    /// Development aid: with `PIER_SELFSHOT=<folder>` set, captures the live dock window, with its
    /// real Liquid Glass, closed and open in every placement. Only the wallpaper, the menu bar,
    /// and Pier are captured, so other apps' windows never end up in a screenshot.
    static func captureLiveWindow(_ window: NSWindow, model: AppModel, to folder: URL) async {
        let dock = model.dock
        typealias CreateImage = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray") else { return }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let saved = (dock.openOnHover, dock.isPinned, dock.placement, dock.notchPins)
        dock.openOnHover = false // the pointer may be resting over the dock
        defer { (dock.openOnHover, dock.isPinned, dock.placement, dock.notchPins) = saved }

        func capture(_ name: String) async {
            try? await Task.sleep(for: .seconds(2))
            guard let image = createImage(.null, windowsToCapture(dock: window), 0)?.takeRetainedValue() else { return }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: folder.appendingPathComponent(name))
        }

        for placement in [DockState.Placement.notch, .right] {
            dock.placement = placement
            for expanded in [false, true] {
                dock.isExpanded = expanded
                dock.isPinned = expanded
                await capture("live-\(placement.rawValue)-\(expanded ? "open" : "closed").png")
            }
        }

        // Readings pinned beside the closed notch.
        dock.placement = .notch
        dock.isExpanded = false
        dock.isPinned = false
        dock.notchPins = [.cpu, .temperature, .memory, .battery]
        await capture("live-notch-pinned.png")

        // A live activity in their place.
        model.activities.show(LiveActivity(symbol: "bolt.fill", text: "64%", tint: .green, spoken: "Charging, 64%"), for: 5)
        await capture("live-notch-activity.png")
    }

    /// Window IDs, front to back: Pier, the menu bar, and the desktop picture.
    private static func windowsToCapture(dock: NSWindow) -> CFArray {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let menuBar = Int(CGWindowLevelForKey(.mainMenuWindow)), statusItems = Int(CGWindowLevelForKey(.statusWindow))
        // The Dock draws the wallpaper one level below the desktop window level.
        let desktop = Int(CGWindowLevelForKey(.desktopWindow))
        var ids = [UInt32(dock.windowNumber)]
        for window in info {
            guard let id = window[kCGWindowNumber as String] as? UInt32, id != ids[0],
                  let layer = window[kCGWindowLayer as String] as? Int,
                  [menuBar, statusItems, desktop, desktop - 1].contains(layer) else { continue }
            ids.append(id)
        }
        var pointers = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        return CFArrayCreate(kCFAllocatorDefault, &pointers, pointers.count, nil)
    }
}
