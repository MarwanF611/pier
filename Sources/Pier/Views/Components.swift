import SwiftUI

/// How worrying a reading is. Color is only ever a second cue next to the number.
enum Severity {
    case normal, elevated, critical

    init(_ fraction: Double, elevated: Double = 0.75, critical: Double = 0.9) {
        self = fraction >= critical ? .critical : fraction >= elevated ? .elevated : .normal
    }

    init(celsius: Double?) {
        guard let celsius else { self = .normal; return }
        self = celsius >= 90 ? .critical : celsius >= 75 ? .elevated : .normal
    }

    var tint: Color {
        switch self {
        case .normal: .primary
        case .elevated: .orange
        case .critical: .red
        }
    }
}

/// Maps a die temperature onto a 0...1 ring: 30 °C reads empty, 100 °C full.
func temperatureFraction(_ celsius: Double?) -> Double {
    guard let celsius else { return 0 }
    return min(1, max(0, (celsius - 30) / 70))
}

/// A circular meter with its value in the middle.
struct RingGauge: View {
    var fraction: Double
    var value: String
    var severity: Severity = .normal
    var diameter: CGFloat = 40
    var lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            Circle()
                .stroke(.primary.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(severity.tint.opacity(severity == .normal ? 0.85 : 1),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: fraction)
            Text(value)
                .font(.system(size: diameter * 0.27, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .padding(.horizontal, lineWidth + 2)
        }
        .frame(width: diameter, height: diameter)
    }
}

/// A horizontal meter, e.g. disk space used.
struct UsageBar: View {
    var fraction: Double
    var severity: Severity = .normal

    var body: some View {
        GeometryReader { proxy in
            Capsule().fill(.primary.opacity(0.12))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(severity.tint.opacity(severity == .normal ? 0.75 : 1))
                        .frame(width: max(6, proxy.size.width * min(1, fraction)))
                }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.6), value: fraction)
    }
}

/// A grouped block of the expanded panel. Sits on the glass as content, so it uses a
/// plain fill rather than more glass.
struct SectionCard<Content: View, Accessory: View>: View {
    var title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                accessory
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.055), in: .rect(cornerRadius: 18))
    }
}

extension SectionCard where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, accessory: { EmptyView() }, content: content)
    }
}

/// Small borderless icon button with a hover highlight and a comfortable hit area.
struct IconButton: View {
    var symbol: String
    var label: String
    var size: CGFloat = 13
    var action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: 28, height: 28)
                .background(.primary.opacity(isHovered ? 0.1 : 0), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

extension Int64 {
    var bytes: String { formatted(.byteCount(style: .file)) }
}

extension UInt64 {
    /// RAM is counted in binary units, so 16 GiB reads "16 GB" as it does in About This Mac.
    var memoryBytes: String { Int64(clamping: self).formatted(.byteCount(style: .memory)) }
}

extension Double {
    var percent: String { "\(Int((self * 100).rounded()))%" }
    /// Network speed, never finer than KB/s: "0 KB/s", "740 KB/s", "12.4 MB/s".
    var rate: String {
        if self < 1_000_000 { return "\(Int((self / 1000).rounded())) KB/s" }
        return (self / 1_000_000).formatted(.number.precision(.fractionLength(1))) + " MB/s"
    }
}

extension TimeInterval {
    /// "3d 4h", "2h 15m", "12m".
    var compactDuration: String {
        let minutes = Int(self) / 60, hours = minutes / 60, days = hours / 24
        if days > 0 { return "\(days)d \(hours % 24)h" }
        if hours > 0 { return "\(hours)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    /// "3:07".
    var clock: String {
        let seconds = Int(self.rounded(.down))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
