import FluidAudio
import Foundation

struct AudioFileTranscript: Equatable, Sendable {
    let transcript: String
    let duration: TimeInterval
}

enum AudioFileTranscriptionUpdate: Equatable, Sendable {
    case decoding(Double)
    case transcribing(Double)
    /// Parakeet's text, available while post-processing is still running.
    case draft(String)
    case polishing(Double)
}

protocol AudioFileTranscribing: Sendable {
    func transcribe(
        _ url: URL,
        postProcessingEnabled: Bool,
        onUpdate: @escaping @Sendable (AudioFileTranscriptionUpdate) -> Void
    ) async throws -> AudioFileTranscript
}

/// Runs a complete file through the same stages as a dictation: Parakeet, then
/// the streaming polisher sentence by sentence, then its final reconciliation.
/// A sentence is one short language-model call, so a dictation that starts
/// during a long file only ever waits for the sentence in flight.
struct AudioFileTranscriber: AudioFileTranscribing {
    let modelRunner: ModelRunner
    let processor: any TranscriptPolishing
    let engine: EngineChoice
    let postProcessingModel: PostProcessingModel

    func transcribe(
        _ url: URL,
        postProcessingEnabled: Bool,
        onUpdate: @escaping @Sendable (AudioFileTranscriptionUpdate) -> Void
    ) async throws -> AudioFileTranscript {
        let samples = try await AudioFileDecoder.decodeMono16k(from: url) { progress in
            onUpdate(.decoding(progress))
        }
        guard samples.count >= ASRConstants.minimumRequiredSamples(
            forSampleRate: Int(AudioSampleLoader.sampleRate)
        ) else {
            throw LocalTranscriberError.audioFileTooShort
        }
        let duration = Double(samples.count) / AudioSampleLoader.sampleRate

        onUpdate(.transcribing(0))
        let rawTranscript = TranscriptCleaner.clean(
            try await modelRunner.transcribeFile(samples, using: engine) { progress in
                onUpdate(.transcribing(progress))
            }
        )
        try Task.checkCancellation()
        guard !rawTranscript.isEmpty else {
            throw LocalTranscriberError.noSpeechDetected
        }
        guard postProcessingEnabled else {
            return AudioFileTranscript(transcript: rawTranscript, duration: duration)
        }

        onUpdate(.draft(rawTranscript))
        onUpdate(.polishing(0))
        let polisher = StreamingTranscriptPolisher(
            isEnabled: true,
            model: postProcessingModel,
            processor: processor
        ) { polished, total in
            onUpdate(.polishing(Double(polished) / Double(total)))
        }
        let result = try await withTaskCancellationHandler {
            await polisher.consumeStableSegment(
                StreamingStableRange(
                    source: rawTranscript,
                    precedingContext: "",
                    followingContext: ""
                )
            )
            await polisher.waitForQueuedWork()
            try Task.checkCancellation()
            return await polisher.finalize(rawTranscript: rawTranscript)
        } onCancel: {
            Task { await polisher.cancel() }
        }
        try Task.checkCancellation()
        return AudioFileTranscript(transcript: result.transcript, duration: duration)
    }
}
