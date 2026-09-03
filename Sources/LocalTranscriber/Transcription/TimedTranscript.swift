import Foundation

/// A silence between two spoken words. `wordIndex` is the index, in the
/// whitespace-separated words of the recognizer's own transcript, of the word
/// that follows the pause.
struct SpeechPause: Sendable, Codable, Equatable {
    let wordIndex: Int
    let seconds: Double
}

/// The recognizer's final transcript together with the pauses it heard.
/// The transcript is the raw recognizer output, before any cleaning, so the
/// pause indices stay valid.
struct TimedTranscript: Sendable, Codable, Equatable {
    let transcript: String
    let pauses: [SpeechPause]

    init(transcript: String, pauses: [SpeechPause] = []) {
        self.transcript = transcript
        self.pauses = pauses
    }
}
