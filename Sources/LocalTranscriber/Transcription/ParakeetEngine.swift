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
        onStableSegment: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        try await prepare()
        guard let manager else {
            throw LocalTranscriberError.modelCouldNotLoad(
                "Parakeet has not been prepared."
            )
        }

        // Parakeet TDT v3 is an offline model. Sliding fixed windows introduced
        // word seams (for example, "four" + "teen") and materially reduced
        // accuracy. Instead, transcribe the cumulative audio every ten seconds.
        // Completed sentences from those snapshots are stable enough for Qwen
        // to polish while recording, while the final pass remains bit-for-bit
        // equivalent to the established whole-recording ASR path.
        let checkpointInterval: TimeInterval = 10
        var nextCheckpoint = checkpointInterval
        var accumulator = LiveAudioAccumulator()
        var emittedSource = ""
        var previousProvisional = ""
        var canEmitStablePrefixes = true

        for await chunk in audioChunks {
            try Task.checkCancellation()
            try accumulator.append(chunk)

            guard accumulator.duration >= nextCheckpoint else { continue }
            while nextCheckpoint <= accumulator.duration {
                nextCheckpoint += checkpointInterval
            }

            let snapshot = try accumulator.mono16kSamples()
            let provisional = TranscriptCleaner.clean(
                try await transcribe(snapshot, with: manager)
            )
            let conservativePrefix = StreamingTranscriptPolicy.stablePrefix(
                of: provisional
            )
            let confirmedPrefix = StreamingTranscriptReconciler.confirmedPrefix(
                in: provisional,
                against: previousProvisional,
                holdingBack: 8
            )
            let confirmedSentencePrefix = StreamingTranscriptPolicy
                .completeSentencePrefix(of: confirmedPrefix)
            previousProvisional = provisional

            guard canEmitStablePrefixes else { continue }
            let candidates = [conservativePrefix, confirmedSentencePrefix]
                .filter { !$0.isEmpty }
                .sorted {
                    StreamingTranscriptReconciler.wordCount(in: $0)
                        > StreamingTranscriptReconciler.wordCount(in: $1)
                }
            guard !candidates.isEmpty else { continue }

            var stablePrefix: String?
            var newSource: String?
            for candidate in candidates {
                guard let suffix = StreamingTranscriptReconciler.unprocessedSuffix(
                    in: candidate,
                    afterProcessedPrefix: emittedSource
                ) else { continue }
                stablePrefix = candidate
                newSource = suffix
                break
            }

            guard let stablePrefix, let newSource else {
                // A cumulative revision changed already-emitted words. Stop
                // speculating; final anchoring will reprocess only unsafe spans.
                canEmitStablePrefixes = false
                continue
            }

            guard !newSource.isEmpty else { continue }
            await onStableSegment(newSource)
            emittedSource = stablePrefix
        }

        try Task.checkCancellation()
        let finalSamples = try accumulator.mono16kSamples()
        return try await transcribe(finalSamples, with: manager)
    }
}
