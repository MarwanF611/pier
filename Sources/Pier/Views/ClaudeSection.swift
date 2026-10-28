import SwiftUI

/// Beside the closed notch while Claude Code works: a turning sparkle and how long it's been
/// at it, or a raised hand when it's waiting on you.
struct ClaudeEar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var session: ClaudeSession

    var body: some View {
        HStack(spacing: 5) {
            if session.isWaitingOnYou {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                Text("Needs you")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Image(systemName: "sparkle")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(ClaudeSessions.tint)
                    .symbolEffect(.rotate.byLayer, options: .repeating, isActive: !reduceMotion)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(context.date.timeIntervalSince(session.turnStartedAt).clock)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(session.isWaitingOnYou ? "Claude needs you in \(session.name)" : "Claude is working in \(session.name)")
    }
}

/// Claude Code sessions, and the switch that connects Pier to them.
struct ClaudeSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let claude = model.claude
        SectionCard(title: "Claude Code") {
            if claude.isConnected {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } content: {
            if claude.isConnected {
                connected(claude)
            } else {
                connect(claude)
            }
        }
    }

    private func connect(_ claude: ClaudeSessions) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("See beside the notch when Claude Code is working, when it needs you, and when it's done.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("Connecting adds a few hooks to ~/.claude/settings.json. Your other settings stay as they are, and a copy of the file is kept next to it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = claude.connectionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button("Connect Claude Code") { claude.connect() }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func connected(_ claude: ClaudeSessions) -> some View {
        @Bindable var claude = claude
        if claude.sessions.isEmpty {
            Text("No sessions yet. Start Claude Code in Terminal or the Claude app, and it shows up here. Sessions that were already running appear after your next message.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 2) {
                ForEach(claude.sessions) { SessionRow(session: $0) }
            }
        }
        HStack {
            Toggle("Play a sound when a long task finishes", isOn: $claude.playsSound)
                .toggleStyle(.checkbox)
                .font(.caption)
            Spacer()
            Button("Disconnect") { claude.disconnect() }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
    }
}

private struct SessionRow: View {
    @Environment(AppModel.self) private var model
    var session: ClaudeSession

    var body: some View {
        HStack(spacing: 10) {
            symbol.frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(detail(at: context.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .contentShape(.rect)
        .contextMenu {
            if let folder = session.folder {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            }
            Button("Forget") { model.claude.forget(session) }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var symbol: some View {
        switch session.state {
        case .working:
            Image(systemName: "sparkle")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(ClaudeSessions.tint)
                .symbolEffect(.rotate.byLayer, options: .repeating)
        case .needsYou:
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .idle:
            Image(systemName: "moon.zzz").foregroundStyle(.secondary)
        }
    }

    private func detail(at now: Date) -> String {
        switch session.state {
        case .working:
            "Working · \(now.timeIntervalSince(session.turnStartedAt).clock)"
        case .needsYou(let message):
            message
        case .done:
            "Done \(session.lastEventAt.compactAge == "now" ? "just now" : session.lastEventAt.compactAge + " ago")"
                + (session.turnDuration.map { " · took \($0.compactDuration == "0m" ? $0.clock : $0.compactDuration)" } ?? "")
        case .idle:
            "Quiet since \(session.lastEventAt.formatted(date: .omitted, time: .shortened))"
        }
    }
}
