import AVFAudio
import CoreMedia
import Foundation
import Speech

/// Turns a recorded lecture into text with Apple's speech recognition on this Mac. English uses
/// the long-form transcriber; Dutch, which it doesn't cover yet, uses the dictation model.
enum LectureTranscriber {
    enum Language: String, CaseIterable, Identifiable {
        case dutch = "nl-BE", english = "en-US"

        var id: String { rawValue }
        var title: String { self == .dutch ? "Dutch" : "English" }
        var short: String { self == .dutch ? "NL" : "EN" }
        var locale: Locale { Locale(identifier: rawValue) }
    }

    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    /// A pause this long between phrases starts a new paragraph.
    private static let paragraphPause = 1.6

    static func transcribe(_ url: URL, language: Language) async throws -> String {
        // The long-form model is the better one for English, but its download can fail; the
        // dictation model is then the fallback, as it is for Dutch.
        if language == .english, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: language.locale) {
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
            if await installAssets(for: transcriber, within: 30),
               let text = try? await run(transcriber, on: url, results: transcriber.results, phrase: { ($0.text, $0.range) }) {
                return text
            }
        }
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: language.locale) else {
            throw Failure(errorDescription: "\(language.title) isn't available for transcription on this Mac.")
        }
        let transcriber = DictationTranscriber(locale: locale, preset: .longDictation)
        return try await run(transcriber, on: url, results: transcriber.results, phrase: { ($0.text, $0.range) })
    }

    private static func run<Results: AsyncSequence>(_ module: any SpeechModule, on url: URL, results: Results,
                                                    phrase: @escaping (Results.Element) -> (AttributedString, CMTimeRange))
        async throws -> String where Results: Sendable {
        try await installAssets(for: module)
        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [module])
        async let phrases = collect(results, phrase)
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        // The results end once the analyzer has worked through the whole file; it has to stay
        // alive until then, or the transcript stops partway.
        let text = paragraphs(try await phrases)
        withExtendedLifetime(analyzer) {}
        return text
    }

    /// Downloads the language's speech model the first time it's used.
    private static func installAssets(for module: any SpeechModule) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }

    /// The same, giving up after a while: a failing download can otherwise hang for minutes.
    private static func installAssets(for module: any SpeechModule, within seconds: Double) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await installAssets(for: module)) != nil }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private static func collect<Results: AsyncSequence>(_ results: Results,
                                                        _ phrase: (Results.Element) -> (AttributedString, CMTimeRange))
        async throws -> [(text: String, range: CMTimeRange)] {
        var phrases: [(String, CMTimeRange)] = []
        for try await result in results {
            let (text, range) = phrase(result)
            phrases.append((String(text.characters), range))
        }
        return phrases
    }

    private static func paragraphs(_ phrases: [(text: String, range: CMTimeRange)]) -> String {
        var output = ""
        var lastEnd: Double?
        for phrase in phrases {
            let text = phrase.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let start = phrase.range.start.seconds
            if let lastEnd, start.isFinite, start - lastEnd >= paragraphPause {
                output += "\n\n"
            } else if !output.isEmpty {
                output += " "
            }
            output += text
            let end = phrase.range.end.seconds
            if end.isFinite { lastEnd = end }
        }
        return output
    }
}
