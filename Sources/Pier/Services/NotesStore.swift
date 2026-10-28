import AppKit
import Observation

/// A folder notes are saved in: the general notes folder, a folder inside it (one per course,
/// say), or any folder elsewhere the user added.
struct NoteFolder: Identifiable, Hashable {
    let url: URL
    var isGeneral = false
    /// Added from somewhere else on the Mac, rather than living in the general folder.
    var isAdded = false

    var id: URL { url }
    var name: String { isGeneral ? "General" : url.lastPathComponent }
}

/// A note is a plain Markdown file, so it opens in any editor and syncs like any file.
struct Note: Identifiable, Hashable {
    let url: URL
    var text: String
    var modified: Date

    var id: URL { url }
    var title: String { url.deletingPathExtension().lastPathComponent }
    /// The first line after the title, for the list.
    var preview: String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        let body = lines.first.map { NotesStore.title(fromLine: $0) == title } == true ? lines.dropFirst() : lines[...]
        return body.first ?? ""
    }
}

/// Quick notes saved as Markdown files, in the folder chosen for each note.
@MainActor
@Observable
final class NotesStore {
    private(set) var root: URL
    private(set) var folders: [NoteFolder] = []
    private(set) var notes: [Note] = []
    /// Where new notes go, and whose notes the list shows.
    private(set) var selected: URL
    /// The note being typed, kept here so it survives the panel closing.
    var draft = ""

    /// Called when a file operation takes long enough that it's probably waiting on a system
    /// permission prompt, which the open panel would cover.
    @ObservationIgnored var onSlowAccess: (() -> Void)?

    private var addedFolders: [URL] {
        didSet { UserDefaults.standard.set(addedFolders.map(\.path), forKey: "noteFolders") }
    }

    nonisolated static let fileExtension = "md"

    init() {
        let defaults = UserDefaults.standard
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = defaults.string(forKey: "notesRoot").map { URL(fileURLWithPath: $0) }
            ?? documents.appendingPathComponent("Pier Notes", isDirectory: true)
        self.root = root
        addedFolders = (defaults.stringArray(forKey: "noteFolders") ?? []).map { URL(fileURLWithPath: $0) }
        selected = defaults.string(forKey: "noteFolder").map { URL(fileURLWithPath: $0) } ?? root
        folders = [NoteFolder(url: root, isGeneral: true)]
    }

    var selectedFolder: NoteFolder {
        folders.first { $0.url == selected } ?? NoteFolder(url: root, isGeneral: true)
    }

    func select(_ folder: NoteFolder) {
        selected = folder.url
        UserDefaults.standard.set(folder.url.path, forKey: "noteFolder")
        Task { await refresh() }
    }

    /// Re-reads the folders and the selected folder's notes from disk.
    func refresh() async {
        let (root, added, selected) = (root, addedFolders, selected)
        let (folders, notes) = await files {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let inside = Self.subfolders(of: root).map { NoteFolder(url: $0) }
            let elsewhere = added.filter { Self.isFolder($0) }.map { NoteFolder(url: $0, isAdded: true) }
            return ([NoteFolder(url: root, isGeneral: true)] + inside + elsewhere, Self.notes(in: selected))
        }
        self.folders = folders
        // The selected folder may have been renamed or removed in Finder.
        if !folders.contains(where: { $0.url == selected }) {
            self.selected = root
            self.notes = await files { Self.notes(in: root) }
        } else {
            self.notes = notes
        }
    }

    /// Saves the draft as a new note in the selected folder. The first line names the file.
    @discardableResult
    func saveDraft() async -> NoteFolder? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let folder = selectedFolder
        let saved = await files {
            // The folder may not exist yet, or may have been removed in Finder.
            try? FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
            let url = Self.freeURL(in: folder.url, base: Self.fileName(for: text))
            return (try? (text + "\n").write(to: url, atomically: true, encoding: .utf8)) != nil
        }
        guard saved else { return nil }
        draft = ""
        await refresh()
        return folder
    }

    func update(_ note: Note, text: String) async {
        guard text != note.text else { return }
        _ = await files { try? text.write(to: note.url, atomically: true, encoding: .utf8) }
        await refresh()
    }

    /// Moves a note to the Trash, where it can still be put back.
    func trash(_ note: Note) async {
        _ = await files { try? FileManager.default.trashItem(at: note.url, resultingItemURL: nil) }
        await refresh()
    }

    /// Makes a folder inside the general folder, e.g. for a new course, and selects it.
    func createFolder(named name: String) async {
        let name = Self.safeName(name)
        guard !name.isEmpty else { return }
        let url = root.appendingPathComponent(name, isDirectory: true)
        _ = await files { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        await refresh()
        if let folder = folders.first(where: { $0.url == url }) { select(folder) }
    }

    /// Adds a folder from elsewhere on the Mac, e.g. a course folder in Documents.
    func addExistingFolder() {
        chooseFolder(message: "Choose a folder to save notes in, like the folder of a course.") { [self] url in
            if url != root, !addedFolders.contains(url) { addedFolders.append(url) }
            Task {
                await refresh()
                if let folder = folders.first(where: { $0.url == url }) { select(folder) }
            }
        }
    }

    /// Removes an added folder from Pier's list. The folder and its notes stay where they are.
    func removeFromList(_ folder: NoteFolder) {
        addedFolders.removeAll { $0 == folder.url }
        if selected == folder.url { select(NoteFolder(url: root, isGeneral: true)) } else { Task { await refresh() } }
    }

    func changeGeneralFolder() {
        chooseFolder(message: "Choose the general folder for notes. Folders inside it show up as their own folders in Pier.") { [self] url in
            let wasGeneral = selected == root
            root = url
            UserDefaults.standard.set(url.path, forKey: "notesRoot")
            if wasGeneral { selected = url; UserDefaults.standard.set(url.path, forKey: "noteFolder") }
            Task { await refresh() }
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Shows a folder picker without blocking Pier, so the notch keeps working while it's open.
    private func chooseFolder(message: String, then use: @escaping (URL) -> Void) {
        // The open panel would sit under Pier's own, so let Pier close first.
        onSlowAccess?()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = message
        NSApp.activate()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { use(url) }
        }
    }

    /// Runs file work off the main thread. If it stalls, it's most likely waiting on a
    /// "Pier would like to access files in your Documents folder" prompt.
    private func files<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        let task = Task.detached(priority: .userInitiated, operation: work)
        let watchdog = Task {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { onSlowAccess?() }
        }
        let value = await task.value
        watchdog.cancel()
        return value
    }

    // MARK: - Files

    nonisolated private static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    nonisolated private static func subfolders(of folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: .skipsHiddenFiles)) ?? []
        return items.filter(isFolder).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    nonisolated private static func notes(in folder: URL) -> [Note] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                  options: .skipsHiddenFiles)) ?? []
        return items.filter { ["md", "txt", "markdown"].contains($0.pathExtension.lowercased()) }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return Note(url: url, text: text, modified: modified)
            }
            .sorted { $0.modified > $1.modified }
    }

    /// A line's text without Markdown heading marks.
    nonisolated static func title(fromLine line: String) -> String {
        safeName(String(line.drop { $0 == "#" || $0 == " " }))
    }

    nonisolated private static func fileName(for text: String) -> String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? ""
        let title = String(title(fromLine: firstLine).prefix(60)).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? "Note " + Date.now.formatted(.iso8601.year().month().day()) : title
    }

    nonisolated private static func safeName(_ name: String) -> String {
        // "Lecture 4: Fourier" becomes "Lecture 4 Fourier"; Finder shows a colon in a name as a slash.
        name.replacingOccurrences(of: ":", with: "")
            .components(separatedBy: CharacterSet(charactersIn: "/\\")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    }

    nonisolated private static func freeURL(in folder: URL, base: String) -> URL {
        var url = folder.appendingPathComponent(base).appendingPathExtension(fileExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(counter)").appendingPathExtension(fileExtension)
            counter += 1
        }
        return url
    }
}
