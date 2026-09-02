import Foundation

actor ModelRunner {
    private let parakeet = ParakeetEngine()

    nonisolated static func isModelDownloaded(_ engine: EngineChoice) -> Bool {
        switch engine {
        case .parakeet:
            return ParakeetEngine.isModelDownloaded()
        }
    }

    func prepare(
        _ engine: EngineChoice,
        progressHandler: ModelProgressHandler? = nil
    ) async throws {
        switch engine {
        case .parakeet:
            try await parakeet.prepare(progressHandler: progressHandler)
        }
    }

    func transcribe(_ samples: [Float], using engine: EngineChoice) async throws -> String {
        switch engine {
        case .parakeet:
            return try await parakeet.transcribe(samples)
        }
    }

    func transcribeStreaming(
        _ audioChunks: AsyncStream<LiveAudioChunk>,
        using engine: EngineChoice,
        onStableSegment: @escaping @Sendable (StreamingStableRange) async -> Void,
        onCheckpoint: (@Sendable (StreamingCheckpointEvent) -> Void)? = nil
    ) async throws -> String {
        switch engine {
        case .parakeet:
            return try await parakeet.transcribeStreaming(
                audioChunks,
                onStableSegment: onStableSegment,
                onCheckpoint: onCheckpoint
            )
        }
    }
}
