import Charts
import SwiftUI

struct ExpandedPanel: View {
    enum Layout {
        /// One column, for the panel on a screen edge.
        case column
        /// Two columns, for the panel hanging from the notch.
        case wide
    }

    var maxHeight: CGFloat
    var layout: Layout = .column

    static let columnWidth: CGFloat = 348

    var body: some View {
        let content = Group {
            switch layout {
            case .column:
                VStack(spacing: 10) {
                    PanelHeader()
                    AssistantSection()
                    SystemSection()
                    StorageSection()
                    MusicSection()
                    ShelfSection()
                    WallpaperSection()
                }
            case .wide:
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 10) {
                        PanelHeader()
                        AssistantSection()
                        SystemSection()
                        StorageSection()
                    }
                    .frame(width: Self.columnWidth)
                    VStack(spacing: 10) {
                        MusicSection()
                        ShelfSection()
                        WallpaperSection()
                    }
                    .frame(width: Self.columnWidth)
                }
            }
        }
        .padding(12)

        // Sized to its content, scrolling only when the screen is too short for it.
        ViewThatFits(in: .vertical) {
            content
            ScrollView(.vertical) { content }
                .scrollIndicators(.never)
        }
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PanelHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var dock = model.dock
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Host.current().localizedName ?? "This Mac")
                    .font(.headline)
                    .lineLimit(1)
                Text("Up \(model.monitor.snapshot.uptime.compactDuration)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            IconButton(symbol: dock.isPinned ? "pin.fill" : "pin",
                       label: dock.isPinned ? "Let Pier Close" : "Keep Pier Open") {
                dock.isPinned.toggle()
            }
            Menu {
                DockContextMenu()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(.circle)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }
}

private struct SystemSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.monitor.snapshot
        SectionCard(title: "System") {
            HStack(spacing: 0) {
                PinnableGauge(label: "CPU", stat: .cpu, fraction: s.cpuUsage)
                PinnableGauge(label: "GPU", stat: .gpu, fraction: s.gpuUsage ?? 0)
                PinnableGauge(label: "Memory", stat: .memory, fraction: s.memoryUsage)
                PinnableGauge(label: "CPU Temp", stat: .temperature, fraction: temperatureFraction(s.cpuTemperature))
            }

            CPUHistoryChart(history: model.monitor.cpuHistory)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    detail("memorychip", "\(s.memoryAvailable.memoryBytes) free of \(s.memoryTotal.memoryBytes)")
                    detail("arrow.down.arrow.up", "↓ \(s.downloadRate.rate)  ↑ \(s.uploadRate.rate)")
                }
                GridRow {
                    detail("arrow.triangle.2.circlepath", s.swapUsed > 0 ? "Swap \(s.swapUsed.memoryBytes)" : "No swap in use")
                    if let level = s.batteryLevel {
                        detail(s.isCharging ? "battery.100percent.bolt" : batterySymbol(level),
                               "\(level.percent)\(s.isCharging ? " · Charging" : "")")
                    } else {
                        detail("powerplug", "On power adapter")
                    }
                }
            }
        }
    }

    private func detail(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).lineLimit(1).minimumScaleFactor(0.85)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
        }
        .font(.caption)
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func batterySymbol(_ level: Double) -> String {
        switch level {
        case ..<0.13: "battery.0percent"
        case ..<0.38: "battery.25percent"
        case ..<0.63: "battery.50percent"
        case ..<0.88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

/// A gauge in the open panel. Hover it to pin the reading beside the notch, where it stays
/// visible while Pier is closed.
private struct PinnableGauge: View {
    @Environment(AppModel.self) private var model
    var label: String
    var stat: NotchStat
    var fraction: Double
    @State private var isHovered = false

    var body: some View {
        let dock = model.dock
        let reading = NotchEars.reading(stat, model.monitor.snapshot)
        let pinned = dock.isPinnedToNotch(stat)
        VStack(spacing: 6) {
            RingGauge(fraction: fraction, value: reading.value, severity: reading.severity, diameter: 54, lineWidth: 5)
                .overlay(alignment: .topTrailing) {
                    if pinned || isHovered {
                        Button { dock.toggleNotchPin(stat) } label: {
                            Image(systemName: pinned ? "pin.fill" : "pin")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(pinned ? NotchEars.lantern : .secondary)
                                .frame(width: 20, height: 20)
                                .background(.thinMaterial, in: .circle)
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .offset(x: 8, y: -6)
                        .help(pinned ? "Remove from Notch" : "Show Beside Notch")
                        .accessibilityLabel(pinned ? "Remove \(label) from notch" : "Show \(label) beside notch")
                    }
                }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(pinned ? "Remove from Notch" : "Show Beside Notch") { dock.toggleNotchPin(stat) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityValue(reading.value + (pinned ? ", shown beside notch" : ""))
    }
}

private struct CPUHistoryChart: View {
    var history: [Double]

    var body: some View {
        Chart(Array(history.enumerated()), id: \.offset) { index, value in
            AreaMark(x: .value("Sample", index), y: .value("CPU", value))
                .foregroundStyle(.linearGradient(colors: [Color.primary.opacity(0.22), Color.primary.opacity(0.02)],
                                                 startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Sample", index), y: .value("CPU", value))
                .foregroundStyle(Color.primary.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)
        }
        .chartYScale(domain: 0...1)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 38)
        .overlay(alignment: .topLeading) {
            Text("CPU, last 2 minutes")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement()
        .accessibilityLabel("CPU usage over the last 2 minutes")
        .accessibilityValue("Peak \((history.max() ?? 0).percent), now \((history.last ?? 0).percent)")
    }
}

private struct StorageSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.monitor.snapshot
        let cleaner = model.cleaner
        let pinned = model.dock.isPinnedToNotch(.disk)
        SectionCard(title: "Storage") {
            HStack(spacing: 2) {
                Text("\(s.diskFree.bytes) free of \(s.diskTotal.bytes)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                IconButton(symbol: pinned ? "pin.fill" : "pin",
                           label: pinned ? "Remove from Notch" : "Show Free Space Beside Notch", size: 10) {
                    model.dock.toggleNotchPin(.disk)
                }
                .foregroundStyle(pinned ? NotchEars.lantern : .secondary)
            }
        } content: {
            UsageBar(fraction: s.diskUsage, severity: Severity(s.diskUsage, elevated: 0.85, critical: 0.95))
                .accessibilityLabel("Disk used")
                .accessibilityValue(s.diskUsage.percent)

            switch cleaner.phase {
            case .idle:
                Button("Clean Up…") { cleaner.scan() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            case .scanning:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for files you can remove…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .ready:
                CleanupList()
            case .cleaning:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Cleaning…").font(.caption).foregroundStyle(.secondary)
                }
            case .done(let freed):
                HStack {
                    Label(freed > 0 ? "Freed \(freed.bytes)" : "Nothing left to clean",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Button("Done") { cleaner.cancel() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }
        }
    }
}

/// The review step before anything is removed: what, how big, and an explicit Clean button.
private struct CleanupList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var cleaner = model.cleaner
        VStack(alignment: .leading, spacing: 8) {
            if cleaner.categories.isEmpty {
                Text("Nothing to clean right now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach($cleaner.categories) { $category in
                Toggle(isOn: $category.isSelected) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(category.title).font(.callout)
                            Text(category.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Text(category.size?.bytes ?? "Size unknown")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }

            if cleaner.categories.contains(where: { $0.id == "trash" && $0.isSelected }) {
                Label("Emptying the Trash can't be undone.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Cancel") { cleaner.cancel() }
                    .buttonStyle(.glass)
                Spacer()
                Button(cleaner.selectedSize > 0 ? "Clean \(cleaner.selectedSize.bytes)" : "Clean") {
                    cleaner.cleanSelected { model.monitor.refresh() }
                }
                .buttonStyle(.glassProminent)
                .disabled(!cleaner.categories.contains(where: \.isSelected))
            }
            .controlSize(.small)
        }
    }
}
