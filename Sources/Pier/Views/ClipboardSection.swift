import SwiftUI

/// Recent copies, newest first and pinned ones on top. Click one to copy it again.
struct ClipboardSection: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var copiedID: UUID?

    var body: some View {
        let clipboard = model.clipboard
        SectionCard(title: "Clipboard") {
            HStack(spacing: 4) {
                Button { model.captureText() } label: {
                    Label("Copy Text from Screen", systemImage: "text.viewfinder")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Select an area to copy the text in it (\(AppModel.textCaptureShortcut))")
                if clipboard.items.contains(where: { !$0.isPinned }) {
                    IconButton(symbol: "xmark.bin", label: "Clear History (Keeps Pinned)") { clipboard.clear() }
                }
            }
        } content: {
            if clipboard.items.isEmpty {
                emptyState
            } else {
                searchField
                let items = filtered(clipboard.items)
                ScrollView(.vertical) {
                    LazyVStack(spacing: 2) {
                        ForEach(items) { item in
                            ClipboardRow(item: item, justCopied: copiedID == item.id) { copy(item) }
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: 236)
                .fixedSize(horizontal: false, vertical: items.count <= 6)
                .overlay {
                    if items.isEmpty {
                        Text("Nothing matches “\(search)”").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search", text: $search)
                .textFieldStyle(.plain)
                .font(.callout)
            if !search.isEmpty {
                IconButton(symbol: "xmark.circle.fill", label: "Clear Search", size: 11) { search = "" }
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(.primary.opacity(0.07), in: .capsule)
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "list.clipboard")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            Text("What you copy shows up here")
                .font(.callout)
            Text("Kept on this Mac. Passwords from password managers are skipped.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private func filtered(_ items: [ClipboardItem]) -> [ClipboardItem] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let matching = query.isEmpty ? items : items.filter { $0.preview.localizedStandardContains(query) }
        return matching.filter(\.isPinned) + matching.filter { !$0.isPinned }
    }

    private func copy(_ item: ClipboardItem) {
        model.clipboard.copy(item)
        copiedID = item.id
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if copiedID == item.id { copiedID = nil }
        }
    }
}

private struct ClipboardRow: View {
    @Environment(AppModel.self) private var model
    var item: ClipboardItem
    var justCopied: Bool
    var copy: () -> Void
    @State private var isHovered = false

    var body: some View {
        let clipboard = model.clipboard
        HStack(spacing: 8) {
            leading
            Text(item.preview)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if justCopied {
                Label("Copied", systemImage: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            } else if isHovered {
                IconButton(symbol: item.isPinned ? "pin.slash" : "pin", label: item.isPinned ? "Unpin" : "Pin", size: 11) {
                    clipboard.togglePin(item)
                }
                IconButton(symbol: "xmark", label: "Remove", size: 10) { clipboard.remove(item) }
            } else {
                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(NotchEars.lantern)
                        .accessibilityHidden(true)
                }
                Text(item.copiedAt.compactAge)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(.primary.opacity(isHovered ? 0.08 : 0), in: .rect(cornerRadius: 9))
        .contentShape(.rect(cornerRadius: 9))
        .onHover { isHovered = $0 }
        .onTapGesture(perform: copy)
        .contextMenu {
            Button("Copy", action: copy)
            Button(item.isPinned ? "Unpin" : "Pin") { clipboard.togglePin(item) }
            Divider()
            Button("Remove", role: .destructive) { clipboard.remove(item) }
        }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.preview)
        .accessibilityValue(item.isPinned ? "Pinned" : "")
        .accessibilityHint("Copies it again")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: item.isPinned ? "Unpin" : "Pin") { clipboard.togglePin(item) }
        .accessibilityAction(named: "Remove") { clipboard.remove(item) }
    }

    @ViewBuilder private var leading: some View {
        switch item.content {
        case .image:
            ZStack {
                Rectangle().fill(.primary.opacity(0.08))
                if let image = model.clipboard.thumbnail(for: item) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: 36, height: 24)
            .clipShape(.rect(cornerRadius: 5))
        case .files:
            Image(systemName: "doc")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 20)
        case .text:
            if let icon = AppIcons.icon(for: item.appBundleID) {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            } else {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }
        }
    }

    private var helpText: String {
        guard case .text(let text) = item.content else { return item.preview }
        return String(text.prefix(600))
    }
}

/// App icons by bundle identifier, looked up once.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage?] = [:]

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleID] = icon
        return icon
    }
}
