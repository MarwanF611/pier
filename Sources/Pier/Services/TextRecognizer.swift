import Foundation
import Vision

/// Reads the text in a picture with Apple's on-device text recognition.
enum TextRecognizer {
    static func text(in url: URL) async -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        guard let observations = try? await request.perform(on: url) else { return "" }
        // Vision returns lines in reading order: top to bottom, column by column.
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
