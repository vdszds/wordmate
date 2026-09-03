import FluidAudio
import Foundation

final class ParakeetEngine {
    private var manager: AsrManager?
    private var models: AsrModels?
    private var loadingTask: Task<(AsrModels, AsrManager), Error>?

    static func isModelDownloaded() -> Bool {
        let directory = AsrModels.defaultCacheDirectory(for: .v3)
        return AsrModels.modelsExist(
            at: directory,
            version: .v3,
            encoderPrecision: .int8
        )
    }

    /// Loads Parakeet once. Concurrent callers, such as the launch warm-up and
    /// a recording started before it finished, share one load instead of each
    /// compiling and loading the Core ML models on their own.
    func prepare(progressHandler: ModelProgressHandler? = nil) async throws {
        guard manager == nil else {
            progressHandler?(.init(fractionCompleted: 1, status: "Ready"))
            return
        }

        let task: Task<(AsrModels, AsrManager), Error>
        if let loadingTask {
            task = loadingTask
            progressHandler?(.init(fractionCompleted: 0.98, status: "Loading model…"))
        } else {
            progressHandler?(.init(fractionCompleted: 0.01, status: "Checking model…"))
            task = Task(priority: .userInitiated) {
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
                return (loadedModels, newManager)
            }
            loadingTask = task
        }

        let loaded: (AsrModels, AsrManager)
        do {
            loaded = try await task.value
        } catch {
            if manager == nil { loadingTask = nil }
            throw error
        }

        // Install before honouring cancellation so a finished load is never
        // thrown away because one of its waiters gave up.
        if manager == nil {
            models = loaded.0
            manager = loaded.1
        }
        loadingTask = nil
        try Task.checkCancellation()
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
        try await transcribeWithTimings(samples, with: manager).transcript
    }

    private func transcribeWithTimings(
        _ samples: [Float],
        with manager: AsrManager
    ) async throws -> TimedTranscript {

        // Each benchmark recording is an independent utterance, so start with
        // a clean decoder state instead of carrying context between runs.
        var decoderState = TdtDecoderState.make(
            decoderLayers: await manager.decoderLayerCount
        )
        let result = try await manager.transcribe(
            samples,
            decoderState: &decoderState
        )
        return TimedTranscript(
            transcript: result.text,
            pauses: Self.pauses(in: result.tokenTimings ?? [], text: result.text)
        )
    }

    /// Silences before word starts. Word starts are the SentencePiece tokens
    /// carrying the "▁" prefix; when that reconstruction does not reproduce
    /// the transcript's word count the timings are ignored rather than
    /// mis-anchored.
    static let minimumReportedPauseSeconds = 0.35

    static func pauses(in timings: [TokenTiming], text: String) -> [SpeechPause] {
        guard !timings.isEmpty else { return [] }
        var pauses: [SpeechPause] = []
        var wordCount = 0
        var previousEnd: TimeInterval?
        for timing in timings {
            let token = timing.token
            let startsWord = token.hasPrefix("▁") || token.hasPrefix(" ") || wordCount == 0
            if startsWord {
                if let previousEnd, wordCount > 0 {
                    let gap = timing.startTime - previousEnd
                    if gap >= minimumReportedPauseSeconds {
                        pauses.append(SpeechPause(wordIndex: wordCount, seconds: gap))
                    }
                }
                wordCount += 1
            }
            previousEnd = max(previousEnd ?? 0, timing.endTime)
        }
        let expected = text.split(whereSeparator: \.isWhitespace).count
        guard wordCount == expected else { return [] }
        return pauses
    }

    func transcribeStreaming(
        _ audioChunks: AsyncStream<LiveAudioChunk>,
        onStableSegment: @escaping @Sendable (StreamingStableRange) async -> Void,
        onCheckpoint: (@Sendable (StreamingCheckpointEvent) -> Void)? = nil
    ) async throws -> String {
        try await transcribeStreamingWithTimings(
            audioChunks,
            onStableSegment: onStableSegment,
            onCheckpoint: onCheckpoint
        ).transcript
    }

    func transcribeStreamingWithTimings(
        _ audioChunks: AsyncStream<LiveAudioChunk>,
        onStableSegment: @escaping @Sendable (StreamingStableRange) async -> Void,
        onCheckpoint: (@Sendable (StreamingCheckpointEvent) -> Void)? = nil
    ) async throws -> TimedTranscript {
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
        }

        try Task.checkCancellation()
        let finalSamples = try accumulator.mono16kSamples()

        let finalStarted = clock.now
        let finalTranscript = try await transcribeWithTimings(finalSamples, with: manager)
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
