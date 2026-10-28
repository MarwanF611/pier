import SwiftUI

/// Pier hidden in the notch. Closed, it is an invisible hover target over the camera
/// housing, so nothing shows. Open, the same shape grows down into the panel, the way
/// the Dynamic Island grows out of the top of an iPhone.
struct NotchSurface: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far the top corners flare outward to meet the menu bar.
    private static let flare: CGFloat = 10

    var body: some View {
        let dock = model.dock
        let notch = dock.notchSize
        let expanded = dock.isExpanded

        // The content decides the size; the black shape is drawn behind whatever that is.
        Group {
            if expanded {
                ExpandedPanel(maxHeight: .infinity, layout: .wide)
                    .padding(.top, notch.height - 6)
                    .padding(.horizontal, Self.flare + 4)
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
            } else {
                NotchEars(notch: notch)
                    .padding(.horizontal, Self.flare)
                    .transition(.opacity)
            }
        }
        .background {
            let hasEars = !NotchEars.isEmpty(model)
            NotchShape(flare: Self.flare, bottomRadius: expanded ? 32 : hasEars ? 14 : 10)
                // Closed with nothing to show, the camera housing itself is the notch: drawing a
                // copy over it never lines up exactly, so leave only an invisible hover target.
                .fill(expanded || hasEars ? Color.black : Color.black.opacity(0.001))
                .overlay {
                    NotchShape(flare: Self.flare, bottomRadius: 32)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .opacity(dock.isDropTargeted && expanded ? 1 : 0)
                }
        }
        .fixedSize()
        .environment(\.colorScheme, .dark) // black surface, like the hardware it hangs from
        .shadow(color: .black.opacity(expanded ? 0.35 : 0), radius: 18, y: 8)
        .contentShape(NotchShape(flare: Self.flare, bottomRadius: 10))
        .onDrop(of: ShelfDrop.types, isTargeted: Binding(get: { dock.isDropTargeted }, set: { dock.isDropTargeted = $0 })) {
            ShelfDrop.accept($0, into: model.shelf)
        }
        .onTapGesture { if !expanded { dock.isExpanded = true } }
        // A live activity grows out of the notch and back in, like the Dynamic Island.
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.4, dampingFraction: 0.78),
                   value: model.activities.current?.id)
        .contextMenu { DockContextMenu() }
        .accessibilityElement(children: expanded ? .contain : .combine)
        .accessibilityLabel("Pier")
    }
}

/// What stays visible beside the notch while Pier is closed: artwork and a waveform while
/// music plays, plus any pinned readings, or for a moment a live activity in their place.
/// Both ears get the same width so the shape stays centered on the camera housing.
struct NotchEars: View {
    @Environment(AppModel.self) private var model
    var notch: CGSize

    enum Item: Hashable {
        case artwork, waveform, keepAwake, claude, lecture, focus
        case stat(NotchStat)
        case activitySymbol(String), activityText(String)

        var width: CGFloat {
            switch self {
            case .artwork, .waveform, .keepAwake, .activitySymbol: 22
            case .stat: 54
            case .claude: 82
            case .lecture: 78
            case .focus: 64
            // Roughly the width of the rounded 12 pt text, so a long headphone name gets room.
            case .activityText(let text): min(150, max(40, CGFloat(text.count) * 7.5))
            }
        }
    }

    private static let outerPadding: CGFloat = 12, innerPadding: CGFloat = 8, spacing: CGFloat = 10
    static let lantern = Color(red: 1, green: 0.70, blue: 0.22) // the brand mark's lantern

    @MainActor
    static func items(_ model: AppModel) -> (leading: [Item], trailing: [Item]) {
        let dock = model.dock
        if dock.notchShowsActivities, let activity = model.activities.current {
            return ([.activitySymbol(activity.symbol)], [.activityText(activity.text)])
        }
        let playing = dock.notchShowsMusic && model.music.nowPlaying?.isPlaying == true
        let stats = dock.notchPins.filter { $0 != .battery || model.monitor.snapshot.batteryLevel != nil }
        let leadingStats = stats.enumerated().filter { $0.offset.isMultiple(of: 2) }.map { Item.stat($0.element) }
        let trailingStats = stats.enumerated().filter { !$0.offset.isMultiple(of: 2) }.map { Item.stat($0.element) }
        // Keep Awake stays in sight while it's on, so it isn't left on by accident.
        let awake = model.keepAwake.isOn
        let claude = model.claude.featured != nil
        let lecture = model.lectures.state != .idle
        let focus = model.focus.isActive
        let leading: [Item] = (lecture ? [.lecture] : []) + (playing ? [.artwork] : []) + (claude ? [.claude] : []) + leadingStats
        let trailing: [Item] = trailingStats + (playing ? [.waveform] : []) + (focus ? [.focus] : []) + (awake ? [.keepAwake] : [])
        return (leading, trailing)
    }

    @MainActor
    static func isEmpty(_ model: AppModel) -> Bool {
        let (leading, trailing) = items(model)
        return leading.isEmpty && trailing.isEmpty
    }

    private static func width(of items: [Item]) -> CGFloat {
        guard !items.isEmpty else { return 0 }
        return outerPadding + innerPadding + items.reduce(0) { $0 + $1.width } + spacing * CGFloat(items.count - 1)
    }

    var body: some View {
        let (leading, trailing) = Self.items(model)
        let earWidth = max(Self.width(of: leading), Self.width(of: trailing))
        HStack(spacing: 0) {
            HStack(spacing: Self.spacing) { ForEach(leading, id: \.self, content: view(for:)) }
                .padding(.leading, Self.outerPadding)
                .frame(width: earWidth, alignment: .leading)
            Color.clear.frame(width: notch.width)
            HStack(spacing: Self.spacing) { ForEach(trailing, id: \.self, content: view(for:)) }
                .padding(.trailing, Self.outerPadding)
                .frame(width: earWidth, alignment: .trailing)
        }
        .frame(height: notch.height)
        .clipped()
    }

    @ViewBuilder
    private func view(for item: Item) -> some View {
        switch item {
        case .artwork:
            Group {
                if let artwork = model.music.artwork {
                    Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, height: 22)
            .background(.white.opacity(0.12))
            .clipShape(.rect(cornerRadius: 6))
            .accessibilityLabel(model.music.nowPlaying.map { "Playing \($0.title) by \($0.artist)" } ?? "Playing")
        case .waveform:
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Self.lantern)
                .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
                .frame(width: 22)
                .accessibilityHidden(true)
        case .claude:
            if let session = model.claude.featured {
                ClaudeEar(session: session).frame(width: Item.claude.width, alignment: .leading)
            }
        case .lecture:
            LectureEar().frame(width: Item.lecture.width, alignment: .leading)
        case .focus:
            FocusEar().frame(width: Item.focus.width, alignment: .trailing)
        case .keepAwake:
            Image(systemName: "cup.and.heat.waves.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Self.lantern)
                .frame(width: 22)
                .help(model.keepAwake.summary)
                .accessibilityLabel(model.keepAwake.summary)
        case .activitySymbol(let symbol):
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(model.activities.current?.tint ?? .white)
                .frame(width: 22)
                .accessibilityHidden(true)
        case .activityText(let text):
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(model.activities.current?.tint ?? .white)
                .frame(width: Item.activityText(text).width, alignment: .trailing)
                .accessibilityLabel(model.activities.current?.spoken ?? text)
        case .stat(let stat):
            let reading = Self.reading(stat, model.monitor.snapshot)
            HStack(spacing: 4) {
                Image(systemName: reading.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(reading.value)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(reading.severity == .normal ? Color.white : reading.severity.tint)
            }
            .frame(width: Item.stat(stat).width)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(stat.title)
            .accessibilityValue(reading.value)
        }
    }

    static func reading(_ stat: NotchStat, _ s: SystemSnapshot) -> (symbol: String, value: String, severity: Severity) {
        switch stat {
        case .cpu: return (stat.symbol, s.cpuUsage.percent, Severity(s.cpuUsage))
        case .gpu: return (stat.symbol, s.gpuUsage?.percent ?? "–", Severity(s.gpuUsage ?? 0))
        case .temperature: return (stat.symbol, s.cpuTemperature.map { "\(Int($0.rounded()))°" } ?? "–", Severity(celsius: s.cpuTemperature))
        case .memory: return (stat.symbol, s.memoryUsage.percent, Severity(s.memoryUsage, elevated: 0.85, critical: 0.95))
        case .disk: return (stat.symbol, s.diskFree.compactBytes, Severity(s.diskUsage, elevated: 0.85, critical: 0.95))
        case .battery:
            let level = s.batteryLevel ?? 0
            let symbol = s.isCharging ? "battery.100percent.bolt" : level < 0.2 ? "battery.25percent" : "battery.75percent"
            return (symbol, level.percent, s.isCharging ? .normal : level < 0.1 ? .critical : level < 0.2 ? .elevated : .normal)
        }
    }
}

/// A rectangle hanging from the top edge, with rounded bottom corners and top corners that
/// curve outward into the menu bar like the MacBook notch itself.
struct NotchShape: Shape {
    var flare: CGFloat
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(bottomRadius, (rect.width - flare * 2) / 2, rect.height - flare)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + flare, y: rect.minY + flare),
                          control: CGPoint(x: rect.minX + flare, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + flare, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + flare + r, y: rect.maxY),
                          control: CGPoint(x: rect.minX + flare, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - flare - r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - flare, y: rect.maxY - r),
                          control: CGPoint(x: rect.maxX - flare, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - flare, y: rect.minY + flare))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - flare, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
