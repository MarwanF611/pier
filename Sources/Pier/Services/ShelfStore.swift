import AppKit
import Observation
import QuickLookThumbnailing
import UniformTypeIdentifiers

struct ShelfItem: Identifiable, Codable, Hashable {
    let id: UUID
    let url: URL
    let addedAt: Date
    /// True when the file lives in Pier's own shelf folder (screenshots, dropped images);
    /// false when the shelf only points at a file somewhere else.
    let isOwned: Bool

    var name: String { url.lastPathComponent }
}

/// A temporary holding area for files. Dropped files are referenced where they are, so
/// dragging them back out moves them like any Finder drag; screenshots and dropped image
/// data are written to the shelf folder.
@MainActor
@Observable
final class ShelfStore {
    private(set) var items: [ShelfItem] = []
    private(set) var thumbnails: [UUID: NSImage] = [:]
    /// Most recent addition, so the dock can briefly show what just landed.
    private(set) var lastAdded: ShelfItem?

    let folder: URL
    private let indexURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pier", isDirectory: true)
        folder = support.appendingPathComponent("Shelf", isDirectory: true)
        indexURL = support.appendingPathComponent("shelf.json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        load()
    }

    func add(fileURL url: URL) {
        guard !items.contains(where: { $0.url == url }) else { return }
        let owned = url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path)
        insert(ShelfItem(id: UUID(), url: url, addedAt: .now, isOwned: owned))
    }

    func add(imageData data: Data, type: UTType, suggestedName: String? = nil) {
        let url = newFileURL(base: Self.safeFileName(suggestedName) ?? "Image", extension: type.preferredFilenameExtension ?? "png")
        guard (try? data.write(to: url)) != nil else { return }
        insert(ShelfItem(id: UUID(), url: url, addedAt: .now, isOwned: true))
    }

    /// A fresh path inside the shelf folder, e.g. for a screenshot about to be taken.
    func newFileURL(base: String, extension ext: String) -> URL {
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
        var url = folder.appendingPathComponent("\(base) \(stamp).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(stamp) \(counter).\(ext)")
            counter += 1
        }
        return url
    }

    /// The name a drag source suggested, made safe to use as one path component. A web page
    /// controls this string, so "../../Library/x" must not be able to leave the shelf folder.
    static func safeFileName(_ name: String?) -> String? {
        guard let name else { return nil }
        let cleaned = (name as NSString).deletingPathExtension
            .components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters))
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        return cleaned.isEmpty ? nil : String(cleaned.prefix(80))
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        thumbnails[item.id] = nil
        if item.isOwned { try? FileManager.default.removeItem(at: item.url) }
        save()
    }

    func removeAll() {
        for item in items { remove(item) }
    }

    func open(_ item: ShelfItem) { NSWorkspace.shared.open(item.url) }
    func reveal(_ item: ShelfItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }

    func copyToPasteboard(_ item: ShelfItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item.url as NSURL])
        if let image = NSImage(contentsOf: item.url), UTType(filenameExtension: item.url.pathExtension)?.conforms(to: .image) == true {
            pasteboard.writeObjects([image])
        }
    }

    /// Forgets items whose file was moved or deleted outside Pier (for example dragged out).
    func pruneMissing() {
        let before = items.count
        items.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
        if items.count != before { save() }
    }

    private func insert(_ item: ShelfItem) {
        items.insert(item, at: 0)
        lastAdded = item
        loadThumbnail(for: item)
        save()
    }

    private func loadThumbnail(for item: ShelfItem) {
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url, size: CGSize(width: 144, height: 144), scale: 2, representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            let image = representation?.nsImage
            Task { @MainActor in
                self.thumbnails[item.id] = image ?? NSWorkspace.shared.icon(forFile: item.url.path)
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let saved = try? JSONDecoder().decode([ShelfItem].self, from: data) else { return }
        items = saved.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        items.forEach(loadThumbnail(for:))
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
