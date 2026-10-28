import FoundationModels
import SwiftUI

/// Ask Pier: a question field and the latest answers, or why the on-device model can't run.
struct AssistantSection: View {
    @Environment(AppModel.self) private var model
    @FocusState private var isFocused: Bool

    var body: some View {
        let assistant = model.assistant
        SectionCard(title: "Ask Pier") {
            HStack(spacing: 2) {
                Label("On this Mac", systemImage: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Answers come from Apple's model on this Mac. Nothing is sent anywhere.")
                if !assistant.turns.isEmpty {
                    IconButton(symbol: "square.and.pencil", label: "New Conversation", size: 11) {
                        assistant.reset()
                        isFocused = true
                    }
                    .disabled(assistant.isResponding)
                }
            }
        } content: {
            switch assistant.availability {
            case .available:
                conversation(assistant)
                field(assistant)
            case .unavailable(let reason):
                unavailable(reason, assistant)
            }
        }
        // Apple Intelligence can be turned on, or finish downloading, while the panel is open.
        .task(id: assistant.availability == .available) {
            while !Task.isCancelled, assistant.availability != .available {
                assistant.refreshAvailability()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder
    private func conversation(_ assistant: Assistant) -> some View {
        if !assistant.turns.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(assistant.turns) { turn in
                            TurnView(turn: turn, isLatest: turn.id == assistant.turns.last?.id && assistant.isResponding)
                                .id(turn.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 150)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: assistant.turns.last?.answer) {
                    if let last = assistant.turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func field(_ assistant: Assistant) -> some View {
        @Bindable var assistant = assistant
        return HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NotchEars.lantern)
                .accessibilityHidden(true)
            TextField(assistant.turns.isEmpty ? "Ask about your Mac, or tell Pier what to do" : "Ask a follow-up",
                      text: $assistant.draft)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($isFocused)
                .onSubmit(send)
                .disabled(assistant.isResponding)
            if assistant.isResponding {
                ProgressView().controlSize(.mini)
            } else if !assistant.draft.isEmpty {
                IconButton(symbol: "arrow.up.circle.fill", label: "Ask", size: 16, action: send)
                    .foregroundStyle(NotchEars.lantern)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(.primary.opacity(0.07), in: .capsule)
    }

    private func send() {
        model.assistant.ask(model.assistant.draft)
    }

    @ViewBuilder
    private func unavailable(_ reason: SystemLanguageModel.Availability.UnavailableReason, _ assistant: Assistant) -> some View {
        switch reason {
        case .appleIntelligenceNotEnabled:
            VStack(alignment: .leading, spacing: 8) {
                Text("Ask Pier runs on Apple's model on this Mac. Turn on Apple Intelligence to use it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Apple Intelligence Settings") { assistant.openSettings() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        case .modelNotReady:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Apple's model is still downloading.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .deviceNotEligible:
            Text("Ask Pier needs a Mac with Apple Intelligence.")
                .font(.caption)
                .foregroundStyle(.secondary)
        @unknown default:
            Text("Apple's model isn't available right now.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct TurnView: View {
    var turn: Assistant.Turn
    var isLatest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(turn.question)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if turn.answer.isEmpty, isLatest {
                Text("Thinking…")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                Text(Self.markdown(turn.answer))
                    .font(.callout)
                    .foregroundStyle(turn.failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The model writes the odd **bold** or `code`; render it instead of showing the marks.
    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
