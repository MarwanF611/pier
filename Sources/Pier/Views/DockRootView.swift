import SwiftUI
import UniformTypeIdentifiers

/// The whole dock window: the notch, which the panel grows out of.
struct DockRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let dock = model.dock
        VStack(spacing: 0) {
            NotchSurface()
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { dock.surfaceRect = $0 }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.36, dampingFraction: 0.84), value: dock.isExpanded)
        .animation(.easeOut(duration: 0.15), value: dock.isDropTargeted)
    }
}

/// Turns whatever is dropped on the dock into shelf items.
enum ShelfDrop {
    static let types: [UTType] = [.fileURL, .image]

    @MainActor
    static func accept(_ providers: [NSItemProvider], into shelf: ShelfStore) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in shelf.add(fileURL: url) }
                }
            } else if let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .image) }) {
                // Image data without a file, e.g. dragged from a web page.
                accepted = true
                let name = provider.suggestedName
                _ = provider.loadDataRepresentation(for: type) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in shelf.add(imageData: data, type: type, suggestedName: name) }
                }
            }
        }
        return accepted
    }
}
