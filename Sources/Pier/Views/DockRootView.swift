import SwiftUI
import UniformTypeIdentifiers

/// The whole dock window: either the slim edge strip that morphs into the full panel, or
/// the notch, which the panel grows out of.
struct DockRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass

    static let stripWidth: CGFloat = 64
    static let panelWidth: CGFloat = 372

    var body: some View {
        let dock = model.dock
        GeometryReader { proxy in
            switch dock.placement {
            case .notch:
                VStack(spacing: 0) {
                    NotchSurface()
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { dock.surfaceRect = $0 }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            case .left, .right:
                ZStack(alignment: dock.placement == .right ? .trailing : .leading) {
                    Color.clear
                    GlassEffectContainer {
                        surface(maxHeight: proxy.size.height - 24)
                            .contextMenu { DockContextMenu() }
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { dock.surfaceRect = $0 }
                    .padding(.horizontal, 10)
                }
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.36, dampingFraction: 0.84), value: dock.isExpanded)
        .animation(.easeOut(duration: 0.15), value: dock.isDropTargeted)
    }

    @ViewBuilder
    private func surface(maxHeight: CGFloat) -> some View {
        let dock = model.dock
        if dock.isExpanded {
            ExpandedPanel(maxHeight: maxHeight)
                .frame(width: Self.panelWidth)
                .glassEffect(.regular, in: .rect(cornerRadius: 28))
                .glassEffectID("dock", in: glass)
                .overlay(dropHighlight(cornerRadius: 28))
                .onDrop(of: ShelfDrop.types, isTargeted: dropTargeted) { ShelfDrop.accept($0, into: model.shelf) }
        } else {
            CollapsedStrip()
                .frame(width: Self.stripWidth)
                .glassEffect(.regular, in: .capsule)
                .glassEffectID("dock", in: glass)
                .overlay(dropHighlight(cornerRadius: Self.stripWidth / 2))
                .onDrop(of: ShelfDrop.types, isTargeted: dropTargeted) { ShelfDrop.accept($0, into: model.shelf) }
                .onTapGesture { dock.isExpanded = true }
        }
    }

    private var dropTargeted: Binding<Bool> {
        Binding(get: { model.dock.isDropTargeted }, set: { model.dock.isDropTargeted = $0 })
    }

    private func dropHighlight(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .opacity(model.dock.isDropTargeted ? 1 : 0)
            .allowsHitTesting(false)
    }
}

/// Always-visible glanceable column: the four vitals, what's playing, and the shelf.
struct CollapsedStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.monitor.snapshot
        VStack(spacing: 12) {
            vital("CPU", fraction: s.cpuUsage, value: s.cpuUsage.percent, severity: Severity(s.cpuUsage))
            vital("Temp", fraction: temperatureFraction(s.cpuTemperature),
                  value: s.cpuTemperature.map { "\(Int($0.rounded()))°" } ?? "–",
                  severity: Severity(celsius: s.cpuTemperature),
                  spoken: s.cpuTemperature.map { "\(Int($0.rounded())) degrees Celsius" } ?? "unavailable")
            vital("RAM", fraction: s.memoryUsage, value: s.memoryUsage.percent, severity: Severity(s.memoryUsage, elevated: 0.85, critical: 0.95))
            vital("Disk", fraction: s.diskUsage, value: s.diskFree.compactBytes,
                  severity: Severity(s.diskUsage, elevated: 0.85, critical: 0.95),
                  spoken: "\(s.diskFree.bytes) free")

            Divider().frame(width: 28)
            nowPlaying
            Divider().frame(width: 28)
            shelf
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .contentShape(.capsule)
    }

    private func vital(_ label: String, fraction: Double, value: String, severity: Severity, spoken: String? = nil) -> some View {
        VStack(spacing: 4) {
            RingGauge(fraction: fraction, value: value, severity: severity)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(spoken ?? value)
    }


    @ViewBuilder private var nowPlaying: some View {
        let playing = model.music.nowPlaying
        ZStack {
            if let artwork = model.music.artwork {
                Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 36, height: 36)
        .background(.primary.opacity(0.08))
        .clipShape(.rect(cornerRadius: 9))
        .overlay(alignment: .bottomTrailing) {
            if playing?.isPlaying == true {
                Image(systemName: "waveform")
                    .font(.system(size: 9, weight: .bold))
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .padding(3)
                    .background(.thinMaterial, in: .circle)
                    .offset(x: 5, y: 5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Now playing")
        .accessibilityValue(playing.map { "\($0.title) by \($0.artist)\($0.isPlaying ? "" : ", paused")" } ?? "Nothing")
    }

    private var shelf: some View {
        let count = model.shelf.items.count
        return VStack(spacing: 3) {
            Image(systemName: count == 0 ? "tray" : "tray.full")
                .font(.system(size: 17, weight: .medium))
                .symbolEffect(.bounce, value: count)
            Text(count == 0 ? "Shelf" : "\(count)")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Shelf")
        .accessibilityValue(count == 1 ? "1 item" : "\(count) items")
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
