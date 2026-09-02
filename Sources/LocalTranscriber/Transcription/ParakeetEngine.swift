import FluidAudio
import Foundation

final class ParakeetEngine {
    private var manager: AsrManager?
    private var models: AsrModels?

    static func isModelDownloaded() -> Bool {
        let directory = AsrModels.defaultCacheDirectory(for: .v3)
        return AsrModels.modelsExist(
            at: directory,
            version: .v3,
            encoderPrecision: .int8
        )
    }

    func prepare(progressHandler: ModelProgressHandler? = nil) async throws {
        guard manager == nil else {
            progressHandler?(.init(fractionCompleted: 1, status: "Ready"))
            return
        }

        progressHandler?(.init(fractionCompleted: 0.01, status: "Checking model…"))
        let loadedModels = try await AsrModels.downloadAndLoad(
            version: .v3
        ) { progress in
            let status: String
            switch progress.phase {
            case .listing:
                status = "Checking model files…"
            case let .downloading(completedFiles, totalFiles):
                status = "Downloading file \(min(completedFiles + 1, totalFiles)) of \(totalFiles)…"
            case .compiling:
                status = "Optimizing for this Mac…"
            }
            progressHandler?(
                .init(
                    fractionCompleted: min(0.96, max(0.02, progress.fractionCompleted)),
                    status: status
                )
            )
        }
        progressHandler?(.init(fractionCompleted: 0.97, status: "Loading model…"))
        let newManager = AsrManager(config: .default)
        try await newManager.loadModels(loadedModels)
        models = loadedModels
        manager = newManager
        progressHandler?(.init(fractionCompleted: 1, status: "Ready"))
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else {
            throw LocalTranscriberError.modelCouldNotLoad("Parakeet has not been prepared.")
        }

        return try await transcribe(samples, with: manager)
    }

    private func transcribe(
        _ samples: [Float],
        with manager: AsrManager
    ) async throws -> String {

        // Each benchmark recording is an independent utterance, so start with
        // a clean decoder state instead of carrying context between runs.
        var decoderState = TdtDecoderState.make(
            decoderLayers: await manager.decoderLayerCount
        )
        let result = try await manager.transcribe(
            samples,
            decoderState: &decoderState
        )
        return result.text
    }

    func transcribeStreaming(
        _ audioChunks: AsyncStream<LiveAudioChunk>,
        onStableSegment: @escaping @Sendable (StreamingStableRange) async -> Void,
        onCheckpoint: (@Sendable (StreamingCheckpointEvent) -> Void)? = nil
    ) async throws -> String {
        try await prepare()
        guard let manager else {
            throw LocalTranscriberError.modelCouldNotLoad(
                "Parakeet has not been prepared."
            )
        }

        // Parakeet TDT v3 is an offline model. Sliding fixed windows introduced
        // word seams (for example, "four" + "teen") and materially reduced
        // accuracy. Instead, transcribe the cumulative audio at checkpoints.
        // Completed sentences from those snapshots are stable enough for Qwen
        // to polish while recording, while the final pass remains bit-for-bit
        // equivalent to the established whole-recording ASR path.
        //
        // Polishing runs on its own queue, so the only cost carried by this
        // loop is the cumulative Parakeet pass itself. The checkpoint gap grows
        // with that pass so long recordings never spend most of their time
        // re-transcribing audio.
        let checkpointInterval: TimeInterval = Self.checkpointInterval
        var nextCheckpoint = checkpointInterval
        var accumulator = LiveAudioAccumulator()
        var tracker = StreamingEmissionTracker()
        var committedText = ""
        let clock = ContinuousClock()

        for await chunk in audioChunks {
            try Task.checkCancellation()
            try accumulator.append(chunk)

            guard accumulator.duration >= nextCheckpoint else { continue }

            let snapshot = try accumulator.mono16kSamples()
            let started = clock.now
            let provisional = TranscriptCleaner.clean(
                try await transcribe(snapshot, with: manager)
            )
            let finished = clock.now
            let elapsedSeconds = Self.seconds(started.duration(to: finished))
            onCheckpoint?(
                StreamingCheckpointEvent(
                    kind: .checkpoint,
                    audioSeconds: accumulator.duration,
                    transcriptionSeconds: elapsedSeconds,
                    startedAt: started,
                    finishedAt: finished
                )
            )
            nextCheckpoint = accumulator.duration
                + max(checkpointInterval, elapsedSeconds * Self.minimumCheckpointGapFactor)

            let stableText = StreamingTranscriptPolicy.committedSentencePrefix(
                of: provisional,
                minimumTrailingWords: Self.minimumTrailingWords
            )
            for range in tracker.newRanges(in: stableText) {
                await onStableSegment(range)
            }
            if !stableText.isEmpty {
                committedText = stableText
            }
        }

        try Task.checkCancellation()
        let finalSamples = try accumulator.mono16kSamples()

        // Speculative tail: a short pass over the last seconds of audio finds
        // the text after the last committed sentence, so Qwen can polish it
        // while the authoritative pass runs. The final reconciliation reuses
        // that work only if the whole-recording transcript matches it word
        // for word; otherwise the tail is simply polished again.
        let tailSampleCount = Int(Self.speculativeTailSeconds * AudioSampleLoader.sampleRate)
        if !committedText.isEmpty,
           finalSamples.count > tailSampleCount + Int(AudioSampleLoader.sampleRate) {
            let tailSamples = Array(finalSamples.suffix(tailSampleCount))
            let tailStarted = clock.now
            let tailTranscript = TranscriptCleaner.clean(
                try await transcribe(tailSamples, with: manager)
            )
            let tailFinished = clock.now
            onCheckpoint?(
                StreamingCheckpointEvent(
                    kind: .speculativeTail,
                    audioSeconds: Double(tailSamples.count) / AudioSampleLoader.sampleRate,
                    transcriptionSeconds: Self.seconds(tailStarted.duration(to: tailFinished)),
                    startedAt: tailStarted,
                    finishedAt: tailFinished
                )
            )
            if let tail = StreamingTranscriptReconciler.textFollowing(
                committedText: committedText,
                in: tailTranscript
            ) {
                await onStableSegment(
                    StreamingStableRange(
                        source: tail,
                        precedingContext: StreamingTranscriptPolicy.trailingContext(
                            of: committedText
                        ),
                        followingContext: "",
                        isTerminal: true
                    )
                )
            }
        }

        let finalStarted = clock.now
        let finalTranscript = try await transcribe(finalSamples, with: manager)
        let finalFinished = clock.now
        onCheckpoint?(
            StreamingCheckpointEvent(
                kind: .finalPass,
                audioSeconds: accumulator.duration,
                transcriptionSeconds: Self.seconds(finalStarted.duration(to: finalFinished)),
                startedAt: finalStarted,
                finishedAt: finalFinished
            )
        )
        return finalTranscript
    }

    /// Audio window transcribed at release to locate the uncommitted tail.
    /// It must reach back past the end of the last committed sentence, so it
    /// covers the checkpoint interval plus a long sentence in progress.
    static let speculativeTailSeconds: TimeInterval = 12

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }

    /// Seconds of new audio between cumulative checkpoints.
    static let checkpointInterval: TimeInterval = 5

    /// A checkpoint waits at least this many times the previous checkpoint's
    /// own transcription time, bounding the share of time spent in Parakeet.
    static let minimumCheckpointGapFactor = 3.0

    /// A sentence is committed only when this many further words follow its
    /// boundary in the same snapshot, so a period Parakeet adds at a mid-word
    /// cut is never mistaken for a real sentence end.
    static let minimumTrailingWords = 3
}
