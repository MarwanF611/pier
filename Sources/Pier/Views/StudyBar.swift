import SwiftUI

/// Lecture recording and the focus timer, both for the folder selected in Notes, plus the
/// time studied per course this week.
struct StudyBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                RecordControl()
                Spacer(minLength: 8)
                FocusControl()
            }
            if let problem = model.lectures.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            WeekTotals()
        }
    }
}

private struct RecordControl: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var lectures = model.lectures
        HStack(spacing: 4) {
            switch lectures.state {
            case .idle:
                Button {
                    Task { await lectures.start(in: model.notes.selectedFolder) }
                } label: {
                    Label("Record Lecture", systemImage: "record.circle")
                }
                .buttonStyle(.glass)
                .help("Record into \(model.notes.selectedFolder.name), then save what was said as a note (\(AppModel.recordShortcut))")
                Picker("Language", selection: $lectures.language) {
                    ForEach(LectureTranscriber.Language.allCases) { Text($0.short).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Language of the lecture")
            case .recording, .paused:
                let recording = lectures.state == .recording
                Image(systemName: "circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(recording ? .red : .secondary)
                    .symbolEffect(.pulse, options: .repeating, isActive: recording)
                    .accessibilityHidden(true)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(lectures.elapsed.lectureClock)
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                }
                Text(lectures.folder?.name ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                IconButton(symbol: recording ? "pause.fill" : "play.fill", label: recording ? "Pause Recording" : "Resume Recording",
                           size: 12) { recording ? lectures.pause() : lectures.resume() }
                Button("Stop & Transcribe") { lectures.stop() }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
            case .transcribing:
                ProgressView().controlSize(.small)
                Text("Writing the transcript…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
    }
}

private struct FocusControl: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let focus = model.focus
        HStack(spacing: 4) {
            if focus.isActive {
                let running = { if case .running = focus.state { true } else { false } }()
                Image(systemName: "timer")
                    .foregroundStyle(NotchEars.lantern)
                    .accessibilityHidden(true)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(focus.remaining.clock)
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                }
                IconButton(symbol: running ? "pause.fill" : "play.fill", label: running ? "Pause Focus" : "Resume Focus", size: 12) {
                    running ? focus.pause() : focus.resume()
                }
                IconButton(symbol: "stop.fill", label: "Stop Focus", size: 11) { focus.stop() }
            } else {
                Menu {
                    ForEach(FocusTimer.durations, id: \.self) { minutes in
                        Button("\(minutes) Minutes") { focus.start(minutes: minutes, course: model.notes.selectedFolder) }
                    }
                } label: {
                    Label("Focus", systemImage: "timer")
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .fixedSize()
                .help("Study \(model.notes.selectedFolder.name) with a timer (\(AppModel.focusShortcut) for 25 minutes)")
            }
        }
        .controlSize(.small)
    }
}

/// "This week: Signals 2h 10m · Math 45m".
private struct WeekTotals: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let totals = model.focus.thisWeek(now: context.date)
            if !totals.isEmpty {
                HStack(spacing: 6) {
                    Text("This week")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(totals, id: \.course) { total in
                        Text("\(total.course) \(total.seconds.compactDuration)")
                            .font(.caption)
                            .monospacedDigit()
                            .padding(.horizontal, 7)
                            .frame(height: 18)
                            .background(.primary.opacity(0.08), in: .capsule)
                    }
                }
                .lineLimit(1)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Beside the closed notch while a lecture records: a red dot and the time recorded.
struct LectureEar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let lectures = model.lectures
        HStack(spacing: 5) {
            if lectures.state == .transcribing {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NotchEars.lantern)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                Text("Writing")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(lectures.state == .recording ? .red : .gray)
                    .symbolEffect(.pulse, options: .repeating, isActive: lectures.state == .recording)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(lectures.elapsed.lectureClock)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lectures.state == .transcribing ? "Writing the lecture transcript" : "Recording a lecture")
    }
}

/// Beside the closed notch during a focus session: the time left.
struct FocusEar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let focus = model.focus
        HStack(spacing: 5) {
            Image(systemName: "timer")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NotchEars.lantern)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(focus.remaining.clock)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Focus on \(focus.course?.name ?? "study")")
        .accessibilityValue("\(focus.remaining.clock) left")
    }
}

extension TimeInterval {
    /// "12:04", or "1:12:04" past an hour.
    var lectureClock: String {
        let seconds = Int(self)
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : clock
    }
}
