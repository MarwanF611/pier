import SwiftUI

struct ShelfSection: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 8)]

    var body: some View {
        let shelf = model.shelf
        SectionCard(title: "Shelf") {
            HStack(spacing: 0) {
                IconButton(symbol: "camera.viewfinder", label: "Take Screenshot to Shelf (\(AppModel.screenshotShortcut))") {
                    model.captureScreenshot()
                }
                if !shelf.items.isEmpty {
                    IconButton(symbol: "xmark.bin", label: "Clear Shelf") { shelf.removeAll() }
                }
            }
        } content: {
            if shelf.items.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical) {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(shelf.items) { ShelfTile(item: $0) }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: shelf.items.count > 8 ? 176 : nil)
                .fixedSize(horizontal: false, vertical: shelf.items.count <= 8)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            Text("Drop files here to keep them handy")
                .font(.callout)
            Text("Screenshots from \(AppModel.screenshotShortcut) land here too")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
        }
    }
}

private struct ShelfTile: View {
    @Environment(AppModel.self) private var model
    var item: ShelfItem
    @State private var isHovered = false

    var body: some View {
        let shelf = model.shelf
        VStack(spacing: 4) {
            ZStack {
                if let image = shelf.thumbnails[item.id] {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 64, height: 52)
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)

            Text(item.name)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
        }
        .padding(4)
        .frame(maxWidth: .infinity)
        .background(.primary.opacity(isHovered ? 0.08 : 0), in: .rect(cornerRadius: 10))
        .overlay(alignment: .topTrailing) {
            if isHovered {
                Button { shelf.remove(item) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .offset(x: 3, y: -3)
                .help("Remove from Shelf")
                .accessibilityLabel("Remove from Shelf")
            }
        }
        .contentShape(.rect(cornerRadius: 10))
        .onHover { isHovered = $0 }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { shelf.open(item) }
        .contextMenu {
            Button("Open") { shelf.open(item) }
            Button("Show in Finder") { shelf.reveal(item) }
            Button("Copy") { shelf.copyToPasteboard(item) }
            Divider()
            Button(item.isOwned ? "Delete" : "Remove from Shelf", role: item.isOwned ? .destructive : nil) {
                shelf.remove(item)
            }
        }
        .help(item.name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.name)
        .accessibilityHint("Drag to move it, double-click to open")
    }
}
