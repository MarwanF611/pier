import AppKit
import AVFAudio
import IOKit.pwr_mgt
import Observation

/// Records a lecture into a course folder, then writes a note next to the audio with what was
/// said, transcribed on this Mac. The audio stays, so nothing is lost if transcription misses
/// a word.
@MainActor
@Observable
final class LectureRecorder {
    enum State: Equatable {
        case idle, recording, paused, transcribing
    }

    private(set) var state = State.idle
    /// The folder the recording and its note go to.
    private(set) var folder: NoteFolder?
    /// Why the last recording couldn't start or be transcribed.
    private(set) var problem: String?
    var language = LectureTranscriber.Language(rawValue: UserDefaults.standard.string(forKey: "lectureLanguage") ?? "") ?? .dutch {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "lectureLanguage") }
    }

    @ObservationIgnored private let notes: NotesStore
    @ObservationIgnored private let activities: LiveActivities
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var startedAt = Date.now
    @ObservationIgnored private var assertion = IOPMAssertionID(0)
    /// Called before a system prompt that the open panel would cover.
    @ObservationIgnored var onPrompt: (() -> Void)?

    /// Good enough for speech recognition to catch every word; lower AAC bitrates drop some.
    /// About 43 MB an hour.
    private static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000,
    ]

    init(notes: NotesStore, activities: LiveActivities) {
        self.notes = notes
        self.activities = activities
    }

    var isActive: Bool { state == .recording || state == .paused }
    var elapsed: TimeInterval { recorder?.currentTime ?? 0 }

    func toggle() {
        switch state {
        case .idle: Task { await start(in: notes.selectedFolder) }
        case .recording, .paused: stop()
        case .transcribing: break
        }
    }

    func start(in folder: NoteFolder) async {
        guard state == .idle else { return }
        problem = nil
        guard await microphoneAllowed() else {
            problem = "Pier can't use the microphone. Allow it in System Settings, Privacy & Security, Microphone."
            return
        }
        let base = "Lecture " + Date.now.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)) + " "
            + Date.now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)).replacingOccurrences(of: ":", with: ".")
        let url: URL? = await Task.detached {
            try? FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
            return NotesStore.freeURL(in: folder.url, base: NotesStore.safeName(base), extension: "m4a")
        }.value
        guard let url, let recorder = try? AVAudioRecorder(url: url, settings: Self.settings), recorder.record() else {
            problem = "Couldn't start recording in \(folder.name)."
            return
        }
        self.recorder = recorder
        self.folder = folder
        startedAt = .now
        state = .recording
        // A lecture outlasts the idle sleep timer; keep the Mac up while it records.
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn), "Pier: Recording a lecture" as CFString, &assertion)
        activities.show(LiveActivity(symbol: "record.circle", text: "Recording", tint: .red,
                                     spoken: "Recording a lecture in \(folder.name)"))
    }

    func pause() {
        guard state == .recording else { return }
        recorder?.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        recorder?.record()
        state = .recording
    }

    /// Stops recording and writes the transcript as a note next to the audio.
    func stop() {
        guard isActive, let recorder, let folder else { return }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        IOPMAssertionRelease(assertion)
        state = .transcribing
        Task { await saveTranscript(of: recorder.url, duration: duration, recordedAt: startedAt, in: folder, language: language) }
    }

    /// Transcribes a recording and saves it as a note in the folder beside it.
    func saveTranscript(of audio: URL, duration: TimeInterval, recordedAt: Date, in folder: NoteFolder,
                        language: LectureTranscriber.Language) async {
        state = .transcribing
        defer { state = .idle }
        let transcript: String
        do {
            let text = try await LectureTranscriber.transcribe(audio, language: language)
            transcript = text.isEmpty ? "_No speech was recognized in the recording._" : text
        } catch {
            transcript = "_Couldn't transcribe the recording: \(error.localizedDescription) The audio is kept next to this note._"
        }
        let title = audio.deletingPathExtension().lastPathComponent
        let link = audio.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? audio.lastPathComponent
        let minutes = Int((duration / 60).rounded())
        let length = minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(max(1, minutes)) min"
        let text = """
            # \(title)

            \(folder.name) · \(recordedAt.formatted(date: .abbreviated, time: .shortened)) · \(length) · \(language.title), transcribed on this Mac
            Audio: [\(audio.lastPathComponent)](\(link))

            \(transcript)

            """
        guard await notes.write(text, named: title, in: folder) != nil else {
            problem = "Couldn't save the transcript in \(folder.name). The audio is kept."
            return
        }
        activities.show(LiveActivity(symbol: "waveform", text: "Lecture saved", tint: .green,
                                     spoken: "Lecture transcript saved in \(folder.name)"), for: 5)
    }

    private func microphoneAllowed() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default:
            onPrompt?()
            NSApp.activate()
            return await AVAudioApplication.requestRecordPermission()
        }
    }
}
