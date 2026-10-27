import AppKit
import Observation

/// A group of files that can go without losing anything the user made.
struct CleanupCategory: Identifiable, Sendable {
    enum Method: Sendable {
        /// Delete everything inside these folders; apps rebuild it as needed.
        case deleteContents([URL])
        /// Move matching files older than `days` to the Trash, so they can still be recovered.
        case moveOldFilesToTrash(folder: URL, extensions: Set<String>, days: Int)
        /// Ask Finder to empty the Trash.
        case emptyTrash
    }

    let id: String
    let title: String
    let detail: String
    let symbol: String
    let method: Method
    var size: Int64?
    var isSelected: Bool
}

@MainActor
@Observable
final class StorageCleaner {
    enum Phase: Equatable { case idle, scanning, ready, cleaning, done(freed: Int64) }

    private(set) var phase: Phase = .idle
    var categories: [CleanupCategory] = []

    var selectedSize: Int64 {
        categories.filter(\.isSelected).reduce(0) { $0 + ($1.size ?? 0) }
    }

    func scan() {
        phase = .scanning
        Task.detached(priority: .userInitiated) {
            let scanned = Self.defaultCategories().map { category in
                var category = category
                category.size = Self.size(of: category.method)
                return category
            }
            .filter { $0.size.map { $0 > 0 } ?? true }
            await MainActor.run {
                self.categories = scanned
                self.phase = .ready
            }
        }
    }

    func cancel() {
        phase = .idle
        categories = []
    }

    func cleanSelected(then completion: @escaping @MainActor () -> Void) {
        let selected = categories.filter(\.isSelected)
        guard !selected.isEmpty else { return }
        phase = .cleaning
        Task.detached(priority: .userInitiated) {
            let freed = selected.reduce(Int64(0)) { total, category in
                let before = category.size ?? 0
                Self.clean(category.method)
                return total + max(0, before - (Self.size(of: category.method) ?? 0))
            }
            await MainActor.run {
                self.phase = .done(freed: freed)
                self.categories = []
                completion()
            }
        }
    }

    // MARK: - Categories

    nonisolated private static func defaultCategories() -> [CleanupCategory] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library")
        let developer = library.appendingPathComponent("Developer")
        return [
            CleanupCategory(
                id: "caches", title: "App Caches", detail: "Apps rebuild these as needed",
                symbol: "shippingbox", method: .deleteContents([library.appendingPathComponent("Caches")]),
                isSelected: true),
            CleanupCategory(
                id: "logs", title: "Logs", detail: "Old diagnostic logs",
                symbol: "doc.text", method: .deleteContents([library.appendingPathComponent("Logs")]),
                isSelected: true),
            CleanupCategory(
                id: "xcode", title: "Xcode Build Data", detail: "DerivedData and simulator caches",
                symbol: "hammer", method: .deleteContents([
                    developer.appendingPathComponent("Xcode/DerivedData"),
                    developer.appendingPathComponent("CoreSimulator/Caches"),
                ]),
                isSelected: true),
            CleanupCategory(
                id: "npm", title: "npm Cache", detail: "Packages npm downloads again on install",
                symbol: "cube", method: .deleteContents([home.appendingPathComponent(".npm/_cacache")]),
                isSelected: true),
            CleanupCategory(
                id: "installers", title: "Old Installers", detail: "Disk images and packages in Downloads older than 2 weeks, moved to the Trash",
                symbol: "arrow.down.app", method: .moveOldFilesToTrash(
                    folder: home.appendingPathComponent("Downloads"), extensions: ["dmg", "pkg"], days: 14),
                isSelected: false),
            CleanupCategory(
                id: "trash", title: "Trash", detail: "Permanently erases what's in the Trash",
                symbol: "trash", method: .emptyTrash,
                isSelected: false),
        ]
    }

    // MARK: - File work

    nonisolated private static func size(of method: CleanupCategory.Method) -> Int64? {
        switch method {
        case .deleteContents(let folders):
            return folders.reduce(0) { $0 + allocatedSize(of: $1) }
        case let .moveOldFilesToTrash(folder, extensions, days):
            return oldFiles(in: folder, extensions: extensions, days: days).reduce(0) { $0 + allocatedSize(of: $1) }
        case .emptyTrash:
            // Reading ~/.Trash needs Full Disk Access; without it the size is unknown, not zero.
            let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
            guard (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) != nil else { return nil }
            return allocatedSize(of: trash)
        }
    }

    nonisolated private static func clean(_ method: CleanupCategory.Method) {
        let fileManager = FileManager.default
        switch method {
        case .deleteContents(let folders):
            for folder in folders {
                let children = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                // Items in use or protected by the system are skipped.
                for child in children { try? fileManager.removeItem(at: child) }
            }
        case let .moveOldFilesToTrash(folder, extensions, days):
            for file in oldFiles(in: folder, extensions: extensions, days: days) {
                try? fileManager.trashItem(at: file, resultingItemURL: nil)
            }
        case .emptyTrash:
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
        }
    }

    nonisolated private static func oldFiles(in folder: URL, extensions: Set<String>, days: Int) -> [URL] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)) ?? []
        return files.filter { file in
            guard extensions.contains(file.pathExtension.lowercased()) else { return false }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return (modified ?? .distantFuture) < cutoff
        }
    }

    nonisolated static func allocatedSize(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return 0
        }
        // A plain file has nothing to enumerate.
        if let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
