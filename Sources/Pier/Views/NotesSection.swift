import SwiftUI

/// Quick notes: pick a folder, type, press Return. Every note is a Markdown file in that folder.
struct NotesSection: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Note?
    @State private var newFolderName: String?

    var body: some View {
        let notes = model.notes
        SectionCard(title: "Notes") {
            HStack(spacing: 0) {
                IconButton(symbol: "folder", label: "Show \(notes.selectedFolder.name) in Finder") {
                    notes.reveal(notes.selectedFolder.url)
                }
                Menu {
                    Button("New Folder…") { newFolderName = "" }
                    Button("Add Existing Folder…") { notes.addExistingFolder() }
                    Divider()
                    Button("Change General Folder…") { notes.changeGeneralFolder() }
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(.circle)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a Folder")
                .accessibilityLabel("Add a Folder")
            }
        } content: {
            FolderChips()
            StudyBar()
            if newFolderName != nil {
                NewFolderField(name: $newFolderName)
            } else if let note = editing {
                NoteEditor(note: note) { editing = nil }
            } else {
                Composer()
                NoteList { editing = $0 }
            }
        }
        .task { await notes.refresh() }
        .onChange(of: notes.selected) { editing = nil }
    }
}

/// The folders to save in, as a row of chips; the selected one gets the next note.
private struct FolderChips: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let notes = model.notes
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(notes.folders) { folder in
                    let selected = folder.url == notes.selected
                    Button { notes.select(folder) } label: {
                        Label(folder.name, systemImage: folder.isGeneral ? "tray.full" : "folder")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .foregroundStyle(selected ? Color.black : .primary)
                            .background(selected ? AnyShapeStyle(NotchEars.lantern) : AnyShapeStyle(.primary.opacity(0.08)), in: .capsule)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Show in Finder") { notes.reveal(folder.url) }
                        if folder.isAdded {
                            Button("Remove from Pier") { notes.removeFromList(folder) }
                        }
                    }
                    .help(folder.url.path)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.never)
    }
}

/// Names a new folder inside the general one, e.g. for a course.
private struct NewFolderField: View {
    @Environment(AppModel.self) private var model
    @Binding var name: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("Folder name, like a course", text: Binding(get: { name ?? "" }, set: { name = $0 }))
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($isFocused)
                .onSubmit(create)
                .onExitCommand { name = nil }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(.primary.opacity(0.07), in: .capsule)
            Button("Cancel") { name = nil }
                .buttonStyle(.glass)
            Button("Create", action: create)
                .buttonStyle(.glassProminent)
                .disabled((name ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .controlSize(.small)
        .holdsPanelOpen(while: isFocused)
        .onAppear { isFocused = true }
    }

    private func create() {
        guard let folder = name else { return }
        name = nil
        Task { await model.notes.createFolder(named: folder) }
    }
}

/// Where a note is typed. Return saves it to the selected folder, Shift-Return starts a new line.
private struct Composer: View {
    @Environment(AppModel.self) private var model
    @FocusState private var isFocused: Bool

    var body: some View {
        @Bindable var notes = model.notes
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NotchEars.lantern)
                .accessibilityHidden(true)
            TextField("New note in \(notes.selectedFolder.name). Return saves, ⇧Return adds a line.",
                      text: $notes.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .lineLimit(1...6)
                .focused($isFocused)
                .onSubmit(save)
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    notes.draft += "\n"
                    return .handled
                }
                .onExitCommand { model.dock.closeHeld() }
            if !notes.draft.isEmpty {
                IconButton(symbol: "arrow.up.circle.fill", label: "Save Note", size: 16, action: save)
                    .foregroundStyle(NotchEars.lantern)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.primary.opacity(0.07), in: .rect(cornerRadius: 14))
        .holdsPanelOpen(while: isFocused)
        // ⌃⌥N anywhere lands here, ready to type.
        .task(id: model.dock.noteFocusRequest) {
            guard model.dock.noteFocusRequest > 0 else { return }
            try? await Task.sleep(for: .milliseconds(80))
            isFocused = true
        }
    }

    private func save() {
        Task {
            guard let folder = await model.notes.saveDraft() else { return }
            model.activities.show(LiveActivity(symbol: "note.text", text: "Saved · \(folder.name)", tint: NotchEars.lantern,
                                               spoken: "Note saved in \(folder.name)"))
            model.dock.closeHeld()
        }
    }
}

private struct NoteList: View {
    @Environment(AppModel.self) private var model
    var open: (Note) -> Void

    var body: some View {
        let notes = model.notes
        if notes.notes.isEmpty {
            Text("No notes in \(notes.selectedFolder.name) yet. Press \(AppModel.noteShortcut) anywhere to jot one down.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    ForEach(notes.notes) { note in NoteRow(note: note) { open(note) } }
                }
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: 176)
            .fixedSize(horizontal: false, vertical: notes.notes.count <= 4)
        }
    }
}

private struct NoteRow: View {
    @Environment(AppModel.self) private var model
    var note: Note
    var open: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(note.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if !note.preview.isEmpty {
                    Text(note.preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(note.modified.compactAge)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(.primary.opacity(isHovered ? 0.08 : 0), in: .rect(cornerRadius: 9))
        .contentShape(.rect(cornerRadius: 9))
        .onHover { isHovered = $0 }
        .onTapGesture(perform: open)
        .onDrag { NSItemProvider(contentsOf: note.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Edit", action: open)
            Button("Open in Editor") { NSWorkspace.shared.open(note.url) }
            Button("Show in Finder") { model.notes.reveal(note.url) }
            Button("Copy Text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(note.text, forType: .string)
            }
            Divider()
            Button("Move to Trash", role: .destructive) { Task { await model.notes.trash(note) } }
        }
        .help("Click to edit, drag to use the file elsewhere")
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the note")
        .accessibilityAddTraits(.isButton)
    }
}

/// Edits a note in place, saving as you type.
private struct NoteEditor: View {
    @Environment(AppModel.self) private var model
    var note: Note
    var close: () -> Void
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(note: Note, close: @escaping () -> Void) {
        self.note = note
        self.close = close
        _text = State(initialValue: note.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                Button { save(); close() } label: {
                    Label("Notes", systemImage: "chevron.left").font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
                Text(note.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                IconButton(symbol: "arrow.up.forward.app", label: "Open in Editor", size: 12) {
                    save()
                    NSWorkspace.shared.open(note.url)
                }
            }
            TextEditor(text: $text)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .padding(6)
                .frame(height: 176)
                .background(.primary.opacity(0.07), in: .rect(cornerRadius: 12))
                .onExitCommand { save(); close() }
        }
        .holdsPanelOpen(while: isFocused)
        .onAppear { isFocused = true }
        // Saved shortly after typing stops, and when leaving the editor.
        .task(id: text) {
            try? await Task.sleep(for: .seconds(0.8))
            if !Task.isCancelled { save() }
        }
        .onDisappear(perform: save)
    }

    private func save() {
        let text = text
        Task { await model.notes.update(note, text: text) }
    }
}

private struct HoldsPanelOpen: ViewModifier {
    @Environment(AppModel.self) private var model
    var isFocused: Bool

    func body(content: Content) -> some View {
        content.onChange(of: isFocused) { if isFocused { model.dock.isHeldOpen = true } }
    }
}

extension View {
    /// Keeps the panel open while typing in this field, even with the pointer elsewhere,
    /// until a click outside Pier, Escape, or saving closes it.
    func holdsPanelOpen(while isFocused: Bool) -> some View {
        modifier(HoldsPanelOpen(isFocused: isFocused))
    }
}
