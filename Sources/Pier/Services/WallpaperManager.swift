import AppKit
import ImageIO
import Observation

struct Wallpaper: Identifiable, Hashable {
    let url: URL
    /// Small image used for the picker; system wallpapers ship a prebuilt one.
    let thumbnailURL: URL
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

@MainActor
@Observable
final class WallpaperManager {
    private(set) var wallpapers: [Wallpaper] = []
    private(set) var thumbnails: [URL: NSImage] = [:]
    private(set) var current: URL?
    @ObservationIgnored private var loadingThumbnails: Set<URL> = []

    /// A folder of the user's own pictures, shown before the system wallpapers.
    var customFolder: URL? {
        didSet {
            UserDefaults.standard.set(customFolder?.path, forKey: "wallpaperFolder")
            reload()
        }
    }

    nonisolated private static let systemFolder = URL(fileURLWithPath: "/System/Library/Desktop Pictures")
    nonisolated private static let imageExtensions: Set<String> = ["heic", "jpg", "jpeg", "png", "tiff", "webp"]

    init() {
        if let path = UserDefaults.standard.string(forKey: "wallpaperFolder") {
            customFolder = URL(fileURLWithPath: path)
        }
        reload()
    }

    func reload() {
        current = NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        let folder = customFolder
        Task.detached(priority: .utility) {
            let list = (folder.map(Self.images(in:)) ?? []) + Self.systemWallpapers()
            await MainActor.run { self.wallpapers = list }
        }
    }

    func apply(_ wallpaper: Wallpaper) {
        for screen in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(wallpaper.url, for: screen, options: [:])
        }
        current = wallpaper.url
    }

    func shuffle() {
        guard let pick = wallpapers.filter({ $0.url != current }).randomElement() else { return }
        apply(pick)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder of pictures to use as wallpapers."
        NSApp.activate()
        if panel.runModal() == .OK { customFolder = panel.url }
    }

    func thumbnail(for wallpaper: Wallpaper) -> NSImage? {
        if let image = thumbnails[wallpaper.thumbnailURL] { return image }
        let url = wallpaper.thumbnailURL
        guard loadingThumbnails.insert(url).inserted else { return nil }
        Task.detached(priority: .utility) {
            guard let image = Self.downsample(url, maxPixel: 240) else { return }
            await MainActor.run { self.thumbnails[url] = image }
        }
        return nil
    }

    nonisolated private static func images(in folder: URL) -> [Wallpaper] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return files
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { Wallpaper(url: $0, thumbnailURL: $0) }
    }

    /// The pictures in System Settings › Wallpaper that are on disk. Dynamic `.madesktop`
    /// wallpapers are skipped: many are aerials that only exist after a download.
    nonisolated private static func systemWallpapers() -> [Wallpaper] {
        let thumbnails = systemFolder.appendingPathComponent(".thumbnails")
        return images(in: systemFolder).map { wallpaper in
            let thumbnail = thumbnails.appendingPathComponent(wallpaper.url.lastPathComponent)
            let hasThumbnail = FileManager.default.fileExists(atPath: thumbnail.path)
            return Wallpaper(url: wallpaper.url, thumbnailURL: hasThumbnail ? thumbnail : wallpaper.url)
        }
    }

    nonisolated static func downsample(_ url: URL, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
