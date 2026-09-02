import Foundation

enum LocalTranscriberError: LocalizedError {
    case alreadyRecording
    case notRecording
    case microphonePermissionDenied
    case audioInputConfigurationFailed(String)
    case microphoneUnavailable(String)
    case couldNotStartRecording
    case missingRecording
    case emptyRecording
    case recordingTooShort
    case recordingTooLong
    case audioConversionFailed
    case noSpeechDetected
    case clipboardWriteFailed
    case pasteEventFailed
    case modelDownloadFailed(String)
    case modelChecksumMismatch
    case modelCouldNotLoad(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "A recording is already in progress."
        case .notRecording:
            return "There is no active recording to stop."
        case .microphonePermissionDenied:
            return "Microphone access is disabled. Enable it in System Settings → Privacy & Security → Microphone."
        case let .audioInputConfigurationFailed(name):
            return "The microphone “\(name)” could not be selected."
        case let .microphoneUnavailable(message):
            return message
        case .couldNotStartRecording:
            return "The microphone recording could not be started."
        case .missingRecording:
            return "The recorded audio file could not be found."
        case .emptyRecording:
            return "The recording was empty."
        case .recordingTooShort:
            return "The recording is too short. Record at least a tenth of a second."
        case .recordingTooLong:
            return "The recording is too long to process."
        case .audioConversionFailed:
            return "The recording could not be converted to 16 kHz mono audio."
        case .noSpeechDetected:
            return "No speech was detected."
        case .clipboardWriteFailed:
            return "The transcript could not be copied to the clipboard."
        case .pasteEventFailed:
            return "The transcript was copied, but the paste command could not be sent."
        case let .modelDownloadFailed(reason):
            return "The model download failed: \(reason)"
        case .modelChecksumMismatch:
            return "The downloaded model failed its checksum verification."
        case let .modelCouldNotLoad(reason):
            return "The model could not be loaded: \(reason)"
        case let .transcriptionFailed(reason):
            return "Transcription failed: \(reason)"
        }
    }
}
