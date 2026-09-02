import Foundation
import XCTest
@testable import LocalTranscriber

final class StreamingAudioPipelineBenchmarkTests: XCTestCase {
    private struct Fixture: Decodable {
        let name: String
        let audioPath: String
        let referencePath: String
    }

    private struct PipelineCompletion: Sendable {
        let result: LiveDictationResult
        let rawCompletedAt: Double
        let finalCompletedAt: Double
    }

    private struct RunResult: Sendable {
        let rawTranscript: String
        let polishedTranscript: String
        let audioDuration: Double
        let replayDuration: Double
        let totalDuration: Double
        let releaseToRawDuration: Double
        let rawToFinalDuration: Double
        let releaseToFinalDuration: Double
        let stableMetrics: StreamingEventMetrics.Snapshot
        let finalizationDiagnostics: StreamingFinalizationDiagnostics
        let callRecords: [PostProcessingCallRecord]
        let checkpoints: [StreamingCheckpointEvent]
        let releasedAt: ContinuousClock.Instant
    }

    func testAudioSetThroughProductionStreamingPipeline() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WORDMATE_RUN_STREAMING_BENCHMARK"] == "1" else {
            throw XCTSkip("Run explicitly with WORDMATE_RUN_STREAMING_BENCHMARK=1")
        }
        guard let manifestPath = environment["WORDMATE_STREAMING_BENCHMARK_MANIFEST"] else {
            XCTFail("WORDMATE_STREAMING_BENCHMARK_MANIFEST must point to a JSON manifest")
            return
        }

        let manifestData = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: manifestData)
        XCTAssertFalse(fixtures.isEmpty)

        let replaySpeed = max(
            0,
            Double(environment["WORDMATE_STREAMING_REPLAY_SPEED"] ?? "0") ?? 0
        )
        let iterations = max(
            1,
            Int(environment["WORDMATE_STREAMING_ITERATIONS"] ?? "1") ?? 1
        )
        let shouldPrintTranscripts = environment["WORDMATE_BENCHMARK_PRINT_TRANSCRIPTS"] == "1"
        let clock = ContinuousClock()
        let runner = ModelRunner()
        let processor = TranscriptPostProcessor()

        let parakeetPreparationStarted = clock.now
        try await runner.prepare(.parakeet)
        let parakeetPreparationDuration = benchmarkSeconds(
            parakeetPreparationStarted.duration(to: clock.now)
        )

        let qwenPreparationStarted = clock.now
        try await processor.prepare(.qwen3_0_6b)
        let qwenPreparationDuration = benchmarkSeconds(
            qwenPreparationStarted.duration(to: clock.now)
        )

        print("WORDMATE PRODUCTION STREAMING BENCHMARK")
        print("REPLAY_SPEED=\(format(replaySpeed))")
        print("ITERATIONS=\(iterations)")
        print("PARAKEET_PREPARE_SECONDS=\(format(parakeetPreparationDuration))")
        print("QWEN_PREPARE_SECONDS=\(format(qwenPreparationDuration))")

        // Warm the inference kernels before measuring. Wordmate prepares both
        // models in the background at launch, and long recordings also hide
        // this work before the user releases Fn.
        if let firstFixture = fixtures.first {
            let warmupSamples = try AudioSampleLoader.loadMono16k(
                from: URL(fileURLWithPath: firstFixture.audioPath)
            )
            let warmupFrameCount = min(
                warmupSamples.count,
                Int(AudioSampleLoader.sampleRate * 18)
            )
            let warmupStarted = clock.now
            _ = try await runStreamingPipeline(
                samples: Array(warmupSamples.prefix(warmupFrameCount)),
                replaySpeed: 0,
                runner: runner,
                processor: processor
            )
            print(
                "INFERENCE_WARMUP_SECONDS=\(format(benchmarkSeconds(warmupStarted.duration(to: clock.now))))"
            )
        }

        var aggregateReferenceWords = 0
        var aggregateRawErrors = 0
        var aggregatePolishedErrors = 0

        for fixture in fixtures {
            let audioURL = URL(fileURLWithPath: fixture.audioPath)
            let reference = try String(
                contentsOfFile: fixture.referencePath,
                encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let samples = try AudioSampleLoader.loadMono16k(from: audioURL)

            for iteration in 1...iterations {
                let result = try await runStreamingPipeline(
                    samples: samples,
                    replaySpeed: replaySpeed,
                    runner: runner,
                    processor: processor
                )
                let referenceWordCount = normalizedWords(reference).count
                let rawErrorCount = wordErrorCount(result.rawTranscript, reference)
                let polishedErrorCount = wordErrorCount(
                    result.polishedTranscript,
                    reference
                )
                let rawWER = Double(rawErrorCount) / Double(referenceWordCount)
                let polishedWER = Double(polishedErrorCount)
                    / Double(referenceWordCount)
                aggregateReferenceWords += referenceWordCount
                aggregateRawErrors += rawErrorCount
                aggregatePolishedErrors += polishedErrorCount

                print("SAMPLE_BEGIN")
                print("SAMPLE_NAME=\(fixture.name)")
                print("ITERATION=\(iteration)")
                print("AUDIO_SECONDS=\(format(result.audioDuration))")
                print("REFERENCE_WORDS=\(referenceWordCount)")
                print(
                    "SPEECH_WORDS_PER_MINUTE=\(format(Double(referenceWordCount) * 60 / result.audioDuration))"
                )
                print("REPLAY_SECONDS=\(format(result.replayDuration))")
                print("TOTAL_PIPELINE_SECONDS=\(format(result.totalDuration))")
                print(
                    "PIPELINE_TIMES_REALTIME=\(format(result.audioDuration / result.totalDuration))"
                )
                print("RELEASE_TO_RAW_SECONDS=\(format(result.releaseToRawDuration))")
                print("RAW_TO_FINAL_SECONDS=\(format(result.rawToFinalDuration))")
                print("RELEASE_TO_FINAL_SECONDS=\(format(result.releaseToFinalDuration))")
                print("STABLE_SEGMENT_CALLBACKS=\(result.stableMetrics.callbackCount)")
                print("STABLE_CALLBACKS_FINISHED_BEFORE_RELEASE=\(result.stableMetrics.finishedBeforeRelease)")
                print(
                    "QWEN_WORK_HIDDEN_DURING_RECORDING_SECONDS=\(format(result.stableMetrics.workBeforeRelease))"
                )
                print(
                    "QWEN_WORK_AFTER_RELEASE_SECONDS=\(format(result.stableMetrics.workAfterRelease))"
                )
                print(
                    "FIRST_STABLE_SEGMENT_SECONDS=\(formatOptional(result.stableMetrics.firstStartedAt))"
                )
                print(
                    "FINALIZATION_STRATEGY=\(result.finalizationDiagnostics.strategy.rawValue)"
                )
                print(
                    "FINALIZATION_FULL_PASS_REASON="
                        + (result.finalizationDiagnostics.fullPassReason?.rawValue ?? "none")
                )
                print(
                    "FINALIZATION_COMPLETED_SEGMENTS=\(result.finalizationDiagnostics.completedSegmentCount)"
                )
                print(
                    "FINALIZATION_REUSED_SEGMENTS=\(result.finalizationDiagnostics.reusedSegmentCount)"
                )
                print(
                    "FINALIZATION_REUSED_WORDS=\(result.finalizationDiagnostics.reusedWordCount)"
                )
                print(
                    "FINALIZATION_REPROCESSED_WORDS=\(result.finalizationDiagnostics.reprocessedWordCount)"
                )
                print(
                    "FINALIZATION_REPROCESSED_RANGES=\(result.finalizationDiagnostics.reprocessedRangeCount)"
                )
                print("RAW_WER_PERCENT=\(format(rawWER * 100))")
                print("POLISHED_WER_PERCENT=\(format(polishedWER * 100))")
                printCallRecords(result.callRecords, releasedAt: result.releasedAt)
                printCheckpoints(result.checkpoints, releasedAt: result.releasedAt)

                if shouldPrintTranscripts {
                    print("RAW_TRANSCRIPT_BEGIN")
                    print(result.rawTranscript)
                    print("RAW_TRANSCRIPT_END")
                    print("POLISHED_TRANSCRIPT_BEGIN")
                    print(result.polishedTranscript)
                    print("POLISHED_TRANSCRIPT_END")
                }
                print("SAMPLE_END")

                XCTAssertFalse(result.rawTranscript.isEmpty)
                XCTAssertFalse(result.polishedTranscript.isEmpty)
                XCTAssertLessThanOrEqual(
                    polishedErrorCount,
                    rawErrorCount,
                    "Qwen made \(fixture.name) less accurate than raw Parakeet"
                )
            }
        }


        let aggregateRawWER = Double(aggregateRawErrors)
            / Double(aggregateReferenceWords)
        let aggregatePolishedWER = Double(aggregatePolishedErrors)
            / Double(aggregateReferenceWords)
        print("AGGREGATE_REFERENCE_WORDS=\(aggregateReferenceWords)")
        print("AGGREGATE_RAW_ERRORS=\(aggregateRawErrors)")
        print("AGGREGATE_POLISHED_ERRORS=\(aggregatePolishedErrors)")
        print("AGGREGATE_RAW_WER_PERCENT=\(format(aggregateRawWER * 100))")
        print(
            "AGGREGATE_POLISHED_WER_PERCENT=\(format(aggregatePolishedWER * 100))"
        )
        XCTAssertLessThanOrEqual(
            aggregatePolishedWER,
            aggregateRawWER,
            "Post-processing must not worsen aggregate Parakeet accuracy"
        )
        XCTAssertLessThan(
            aggregatePolishedWER,
            0.14,
            "Production streaming quality regressed above the accepted 14% gate"
        )
    }

    private func runStreamingPipeline(
        samples: [Float],
        replaySpeed: Double,
        runner: ModelRunner,
        processor: TranscriptPostProcessor
    ) async throws -> RunResult {
        let clock = ContinuousClock()
        let audioDuration = Double(samples.count) / AudioSampleLoader.sampleRate
        let metrics = StreamingEventMetrics()
        let checkpointLog = CheckpointLog()
        let polisher = StreamingTranscriptPolisher(
            isEnabled: true,
            model: .qwen3_0_6b,
            processor: processor
        )

        var capturedContinuation: AsyncStream<LiveAudioChunk>.Continuation?
        let stream = AsyncStream<LiveAudioChunk>(bufferingPolicy: .unbounded) {
            capturedContinuation = $0
        }
        guard let continuation = capturedContinuation else {
            throw LocalTranscriberError.audioConversionFailed
        }

        let replayStarted = clock.now
        let pipelineTask = Task(priority: .userInitiated) {
            let rawTranscript = TranscriptCleaner.clean(
                try await runner.transcribeStreaming(
                    stream,
                    using: .parakeet
                ) { stableRange in
                    let stableStartedAt = benchmarkSeconds(
                        replayStarted.duration(to: clock.now)
                    )
                    await polisher.consumeStableSegment(stableRange)
                    let stableFinishedAt = benchmarkSeconds(
                        replayStarted.duration(to: clock.now)
                    )
                    await metrics.recordStableCallback(
                        startedAt: stableStartedAt,
                        finishedAt: stableFinishedAt
                    )
                } onCheckpoint: { event in
                    checkpointLog.append(event)
                }
            )
            let rawCompletedAt = benchmarkSeconds(
                replayStarted.duration(to: clock.now)
            )
            let result = await polisher.finalize(rawTranscript: rawTranscript)
            return PipelineCompletion(
                result: result,
                rawCompletedAt: rawCompletedAt,
                finalCompletedAt: benchmarkSeconds(
                    replayStarted.duration(to: clock.now)
                )
            )
        }

        let framesPerChunk = Int(AudioSampleLoader.sampleRate / 10)
        var offset = 0
        while offset < samples.count {
            let end = min(samples.count, offset + framesPerChunk)
            if replaySpeed > 0 {
                let sourceElapsed = Double(end) / AudioSampleLoader.sampleRate
                let deadline = replayStarted.advanced(
                    by: .seconds(sourceElapsed / replaySpeed)
                )
                try await clock.sleep(until: deadline)
            }

            continuation.yield(
                LiveAudioChunk(mono16kSamples: Array(samples[offset..<end]))
            )
            offset = end
        }

        let releasedInstant = clock.now
        let releasedAt = benchmarkSeconds(replayStarted.duration(to: releasedInstant))
        continuation.finish()
        let completion = try await pipelineTask.value
        let stableMetrics = await metrics.snapshot(releasedAt: releasedAt)
        let callRecords = await processor.drainCallRecords()
        let checkpoints = checkpointLog.events

        return RunResult(
            rawTranscript: completion.result.rawTranscript,
            polishedTranscript: completion.result.transcript,
            audioDuration: audioDuration,
            replayDuration: releasedAt,
            totalDuration: completion.finalCompletedAt,
            releaseToRawDuration: max(0, completion.rawCompletedAt - releasedAt),
            rawToFinalDuration: max(
                0,
                completion.finalCompletedAt - completion.rawCompletedAt
            ),
            releaseToFinalDuration: max(
                0,
                completion.finalCompletedAt - releasedAt
            ),
            stableMetrics: stableMetrics,
            finalizationDiagnostics: completion.result.finalizationDiagnostics,
            callRecords: callRecords,
            checkpoints: checkpoints,
            releasedAt: releasedInstant
        )
    }

    private func printCheckpoints(
        _ events: [StreamingCheckpointEvent],
        releasedAt: ContinuousClock.Instant
    ) {
        let checkpoints = events.filter { $0.kind == .checkpoint }
        let inFlightAtRelease = checkpoints.contains {
            $0.startedAt < releasedAt && $0.finishedAt > releasedAt
        }
        if let tail = events.first(where: { $0.kind == .speculativeTail }) {
            print("PARAKEET_SPECULATIVE_TAIL_SECONDS=\(format(tail.transcriptionSeconds))")
        } else {
            print("PARAKEET_SPECULATIVE_TAIL_SECONDS=none")
        }
        let checkpointSeconds = checkpoints.reduce(0.0) { $0 + $1.transcriptionSeconds }
        print("PARAKEET_CHECKPOINTS=\(checkpoints.count)")
        print("PARAKEET_CHECKPOINT_SECONDS=\(format(checkpointSeconds))")
        print("PARAKEET_CHECKPOINT_IN_FLIGHT_AT_RELEASE=\(inFlightAtRelease)")
        if let last = checkpoints.last {
            print("PARAKEET_LAST_CHECKPOINT_AUDIO_SECONDS=\(format(last.audioSeconds))")
            print("PARAKEET_LAST_CHECKPOINT_SECONDS=\(format(last.transcriptionSeconds))")
        }
        if let finalPass = events.first(where: { $0.kind == .finalPass }) {
            print("PARAKEET_FINAL_PASS_SECONDS=\(format(finalPass.transcriptionSeconds))")
            print(
                "PARAKEET_FINAL_PASS_STARTED_AFTER_RELEASE_SECONDS=\(format(benchmarkSeconds(releasedAt.duration(to: finalPass.startedAt))))"
            )
        }
    }

    /// Prints every Qwen call of a run, then a per-stage summary split by
    /// whether the call finished before or after Fn was released.
    private func printCallRecords(
        _ records: [PostProcessingCallRecord],
        releasedAt: ContinuousClock.Instant
    ) {
        var afterReleaseSeconds = 0.0
        var beforeReleaseSeconds = 0.0
        var stageTotals: [String: (count: Int, seconds: Double)] = [:]
        var outcomeTotals: [String: Int] = [:]
        var promptSeconds = 0.0
        var generationSeconds = 0.0
        var reusedPromptTokens = 0
        var promptTokens = 0

        print("QWEN_CALLS_BEGIN")
        for record in records {
            let startedAfterRelease = record.startedAt >= releasedAt
            let phase: String
            if startedAfterRelease {
                phase = "afterRelease"
                afterReleaseSeconds += record.totalSeconds
            } else if record.finishedAt > releasedAt {
                phase = "spansRelease"
                let overhang = benchmarkSeconds(releasedAt.duration(to: record.finishedAt))
                afterReleaseSeconds += overhang
                beforeReleaseSeconds += record.totalSeconds - overhang
            } else {
                phase = "beforeRelease"
                beforeReleaseSeconds += record.totalSeconds
            }
            let key = record.stage.rawValue
            let previous = stageTotals[key] ?? (0, 0)
            stageTotals[key] = (previous.count + 1, previous.seconds + record.totalSeconds)
            outcomeTotals[record.outcome.rawValue, default: 0] += 1
            promptSeconds += record.promptSeconds
            generationSeconds += record.generationSeconds
            reusedPromptTokens += record.reusedPromptTokenCount
            promptTokens += record.promptTokenCount

            print(
                "QWEN_CALL stage=\(record.stage.rawValue) outcome=\(record.outcome.rawValue) "
                    + "phase=\(phase) words=\(record.sourceWordCount) "
                    + "prompt_tokens=\(record.promptTokenCount) reused_tokens=\(record.reusedPromptTokenCount) "
                    + "generated_tokens=\(record.generatedTokenCount) "
                    + "prompt_seconds=\(format(record.promptSeconds)) "
                    + "generation_seconds=\(format(record.generationSeconds)) "
                    + "total_seconds=\(format(record.totalSeconds))"
            )
            if record.outcome != .accepted {
                print("QWEN_REJECTED_SOURCE=\(record.source)")
                print("QWEN_REJECTED_OUTPUT=\(record.output)")
            }
        }
        print("QWEN_CALLS_END")
        print("QWEN_CALL_COUNT=\(records.count)")
        print("QWEN_CALL_SECONDS_BEFORE_RELEASE=\(format(beforeReleaseSeconds))")
        print("QWEN_CALL_SECONDS_AFTER_RELEASE=\(format(afterReleaseSeconds))")
        print("QWEN_PROMPT_SECONDS=\(format(promptSeconds))")
        print("QWEN_GENERATION_SECONDS=\(format(generationSeconds))")
        print("QWEN_PROMPT_TOKENS=\(promptTokens)")
        print("QWEN_REUSED_PROMPT_TOKENS=\(reusedPromptTokens)")
        for (stage, totals) in stageTotals.sorted(by: { $0.key < $1.key }) {
            print(
                "QWEN_STAGE stage=\(stage) calls=\(totals.count) seconds=\(format(totals.seconds))"
            )
        }
        for (outcome, count) in outcomeTotals.sorted(by: { $0.key < $1.key }) {
            print("QWEN_OUTCOME outcome=\(outcome) calls=\(count)")
        }
    }

    private func wordErrorCount(_ actual: String, _ expected: String) -> Int {
        editDistance(normalizedWords(actual), normalizedWords(expected))
    }

    private func normalizedWords(_ text: String) -> [String] {
        text.lowercased().split { character in
            !character.isLetter && !character.isNumber
        }.map(String.init)
    }

    private func editDistance(_ lhs: [String], _ rhs: [String]) -> Int {
        var previous = Array(0...rhs.count)
        for (lhsIndex, lhsWord) in lhs.enumerated() {
            var current = Array(repeating: 0, count: rhs.count + 1)
            current[0] = lhsIndex + 1
            for (rhsIndex, rhsWord) in rhs.enumerated() {
                current[rhsIndex + 1] = min(
                    previous[rhsIndex + 1] + 1,
                    current[rhsIndex] + 1,
                    previous[rhsIndex] + (lhsWord == rhsWord ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[rhs.count]
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func formatOptional(_ value: Double?) -> String {
        value.map(format) ?? "none"
    }
}

private final class CheckpointLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [StreamingCheckpointEvent] = []

    var events: [StreamingCheckpointEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ event: StreamingCheckpointEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }
}

private actor StreamingEventMetrics {
    struct Snapshot: Sendable {
        let callbackCount: Int
        let finishedBeforeRelease: Int
        let workBeforeRelease: Double
        let workAfterRelease: Double
        let firstStartedAt: Double?
    }

    private struct Callback: Sendable {
        let startedAt: Double
        let finishedAt: Double
    }

    private var callbacks: [Callback] = []

    func recordStableCallback(startedAt: Double, finishedAt: Double) {
        callbacks.append(
            Callback(startedAt: startedAt, finishedAt: finishedAt)
        )
    }

    func snapshot(releasedAt: Double) -> Snapshot {
        let workBeforeRelease = callbacks.reduce(0.0) { total, callback in
            total + max(0, min(callback.finishedAt, releasedAt) - callback.startedAt)
        }
        let workAfterRelease = callbacks.reduce(0.0) { total, callback in
            total + max(0, callback.finishedAt - max(callback.startedAt, releasedAt))
        }
        return Snapshot(
            callbackCount: callbacks.count,
            finishedBeforeRelease: callbacks.count(where: {
                $0.finishedAt <= releasedAt
            }),
            workBeforeRelease: workBeforeRelease,
            workAfterRelease: workAfterRelease,
            firstStartedAt: callbacks.map(\.startedAt).min()
        )
    }
}

private func benchmarkSeconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
}
