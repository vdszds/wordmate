import AVFoundation
import Darwin
import Foundation
import XCTest
@testable import LocalTranscriber

final class LibriSpeechBenchmarkTests: XCTestCase {
    private struct Fixture: Sendable {
        let id: String
        let audioURL: URL
        let reference: String
        let audioDuration: Double
    }

    private struct PipelineCompletion: Sendable {
        let result: LiveDictationResult
        let rawCompletedAt: Double
        let finalCompletedAt: Double
    }

    private struct PipelineRun: Sendable {
        let rawTranscript: String
        let polishedTranscript: String
        let replayDuration: Double
        let totalDuration: Double
        let releaseToRawDuration: Double
        let rawToFinalDuration: Double
        let releaseToFinalDuration: Double
        let stableMetrics: LibriSpeechStreamingMetrics.Snapshot
    }

    private struct ErrorCounts: Sendable {
        var substitutions = 0
        var deletions = 0
        var insertions = 0

        var total: Int {
            substitutions + deletions + insertions
        }

        static func + (lhs: Self, rhs: Self) -> Self {
            Self(
                substitutions: lhs.substitutions + rhs.substitutions,
                deletions: lhs.deletions + rhs.deletions,
                insertions: lhs.insertions + rhs.insertions
            )
        }
    }

    private struct SampleResult: Sendable {
        let index: Int
        let fixture: Fixture
        let rawTranscript: String
        let polishedTranscript: String
        let referenceWordCount: Int
        let rawErrors: ErrorCounts
        let polishedErrors: ErrorCounts
        let replayDuration: Double
        let totalDuration: Double
        let releaseToRawDuration: Double
        let rawToFinalDuration: Double
        let releaseToFinalDuration: Double
        let stableMetrics: LibriSpeechStreamingMetrics.Snapshot

        var rawWER: Double {
            Double(rawErrors.total) / Double(referenceWordCount)
        }

        var polishedWER: Double {
            Double(polishedErrors.total) / Double(referenceWordCount)
        }

        var errorDelta: Int {
            polishedErrors.total - rawErrors.total
        }
    }

    func testDeterministicLibriSpeechCohortThroughProductionPipeline() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WORDMATE_RUN_LIBRISPEECH_BENCHMARK"] == "1" else {
            throw XCTSkip("Run explicitly with WORDMATE_RUN_LIBRISPEECH_BENCHMARK=1")
        }
        guard let datasetPath = environment["WORDMATE_LIBRISPEECH_ROOT"] else {
            XCTFail("WORDMATE_LIBRISPEECH_ROOT must point to a LibriSpeech test split")
            return
        }

        let datasetSplit = environment["WORDMATE_LIBRISPEECH_SPLIT"]
            ?? "test-clean"
        let datasetConfiguration = datasetSplit == "test-other"
            ? "other"
            : "clean"

        let requestedCount = max(
            1,
            Int(environment["WORDMATE_LIBRISPEECH_SAMPLE_COUNT"] ?? "100") ?? 100
        )
        let minimumDuration = max(
            0,
            Double(environment["WORDMATE_LIBRISPEECH_MIN_SECONDS"] ?? "5") ?? 5
        )
        let seed = UInt64(
            environment["WORDMATE_LIBRISPEECH_SEED"] ?? "20260901"
        ) ?? 20_260_901
        let replaySpeed = max(
            0,
            Double(environment["WORDMATE_LIBRISPEECH_REPLAY_SPEED"] ?? "1") ?? 1
        )
        let reportPath = environment["WORDMATE_LIBRISPEECH_REPORT"]
            ?? FileManager.default.currentDirectoryPath
                + "/Benchmarks/librispeech-\(datasetSplit)-\(requestedCount).md"

        let fixtures = try makeFixtures(
            datasetRoot: URL(fileURLWithPath: datasetPath, isDirectory: true),
            count: requestedCount,
            minimumDuration: minimumDuration,
            seed: seed
        )
        XCTAssertEqual(fixtures.count, requestedCount)
        XCTAssertTrue(fixtures.allSatisfy { $0.audioDuration >= minimumDuration })

        let clock = ContinuousClock()
        let runner = ModelRunner()
        let processor = TranscriptPostProcessor()

        let parakeetPreparationStarted = clock.now
        try await runner.prepare(.parakeet)
        let parakeetPreparationDuration = librispeechSeconds(
            parakeetPreparationStarted.duration(to: clock.now)
        )

        let qwenPreparationStarted = clock.now
        try await processor.prepare(.qwen3_0_6b)
        let qwenPreparationDuration = librispeechSeconds(
            qwenPreparationStarted.duration(to: clock.now)
        )

        let warmupSamples = try AudioSampleLoader.loadMono16k(
            from: fixtures[0].audioURL
        )
        let warmupStarted = clock.now
        _ = try await runProductionPipeline(
            samples: warmupSamples,
            replaySpeed: 0,
            runner: runner,
            processor: processor
        )
        let warmupDuration = librispeechSeconds(
            warmupStarted.duration(to: clock.now)
        )

        print("WORDMATE LIBRISPEECH BENCHMARK")
        print("DATASET_SPLIT=\(datasetSplit)")
        print("SAMPLE_COUNT=\(fixtures.count)")
        print("MINIMUM_AUDIO_SECONDS=\(format(minimumDuration))")
        print("SELECTION_SEED=\(seed)")
        print("REPLAY_SPEED=\(format(replaySpeed))")
        print("PARAKEET_PREPARE_SECONDS=\(format(parakeetPreparationDuration))")
        print("QWEN_PREPARE_SECONDS=\(format(qwenPreparationDuration))")
        print("WARMUP_SECONDS=\(format(warmupDuration))")

        var results: [SampleResult] = []
        results.reserveCapacity(fixtures.count)

        for (offset, fixture) in fixtures.enumerated() {
            let result = try await benchmark(
                fixture: fixture,
                index: offset + 1,
                replaySpeed: replaySpeed,
                runner: runner,
                processor: processor
            )
            results.append(result)

            print(
                "LIBRISPEECH_PROGRESS="
                    + "\(result.index)/\(fixtures.count) "
                    + "ID=\(fixture.id) "
                    + "AUDIO_SECONDS=\(format(fixture.audioDuration)) "
                    + "RAW_WER_PERCENT=\(format(result.rawWER * 100)) "
                    + "POLISHED_WER_PERCENT=\(format(result.polishedWER * 100)) "
                    + "RELEASE_TO_FINAL_SECONDS=\(format(result.releaseToFinalDuration))"
            )
        }

        let report = makeReport(
            results: results,
            datasetConfiguration: datasetConfiguration,
            datasetSplit: datasetSplit,
            minimumDuration: minimumDuration,
            seed: seed,
            replaySpeed: replaySpeed,
            parakeetPreparationDuration: parakeetPreparationDuration,
            qwenPreparationDuration: qwenPreparationDuration,
            warmupDuration: warmupDuration
        )
        let reportURL = URL(fileURLWithPath: reportPath)
        try FileManager.default.createDirectory(
            at: reportURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try report.write(to: reportURL, atomically: true, encoding: .utf8)

        let aggregate = aggregateMetrics(results)
        print("AGGREGATE_REFERENCE_WORDS=\(aggregate.referenceWords)")
        print("AGGREGATE_RAW_ERRORS=\(aggregate.rawErrors.total)")
        print("AGGREGATE_POLISHED_ERRORS=\(aggregate.polishedErrors.total)")
        print("AGGREGATE_RAW_WER_PERCENT=\(format(aggregate.rawWER * 100))")
        print("AGGREGATE_POLISHED_WER_PERCENT=\(format(aggregate.polishedWER * 100))")
        print("REPORT_PATH=\(reportURL.path)")

        XCTAssertEqual(results.count, requestedCount)
        XCTAssertTrue(results.allSatisfy { !$0.rawTranscript.isEmpty })
        XCTAssertTrue(results.allSatisfy { !$0.polishedTranscript.isEmpty })
        XCTAssertFalse(
            results.contains { $0.errorDelta > 0 },
            "Qwen must not worsen any recording in the deterministic cohort"
        )
        XCTAssertLessThanOrEqual(
            aggregate.polishedErrors.total,
            aggregate.rawErrors.total,
            "Qwen must not increase aggregate word errors"
        )
    }

    private func benchmark(
        fixture: Fixture,
        index: Int,
        replaySpeed: Double,
        runner: ModelRunner,
        processor: TranscriptPostProcessor
    ) async throws -> SampleResult {
        let samples = try AudioSampleLoader.loadMono16k(from: fixture.audioURL)
        let run = try await runProductionPipeline(
            samples: samples,
            replaySpeed: replaySpeed,
            runner: runner,
            processor: processor
        )
        let referenceWords = normalizedWords(fixture.reference)
        let rawErrors = errorCounts(
            expected: referenceWords,
            actual: normalizedWords(run.rawTranscript)
        )
        let polishedErrors = errorCounts(
            expected: referenceWords,
            actual: normalizedWords(run.polishedTranscript)
        )

        return SampleResult(
            index: index,
            fixture: fixture,
            rawTranscript: run.rawTranscript,
            polishedTranscript: run.polishedTranscript,
            referenceWordCount: referenceWords.count,
            rawErrors: rawErrors,
            polishedErrors: polishedErrors,
            replayDuration: run.replayDuration,
            totalDuration: run.totalDuration,
            releaseToRawDuration: run.releaseToRawDuration,
            rawToFinalDuration: run.rawToFinalDuration,
            releaseToFinalDuration: run.releaseToFinalDuration,
            stableMetrics: run.stableMetrics
        )
    }

    private func runProductionPipeline(
        samples: [Float],
        replaySpeed: Double,
        runner: ModelRunner,
        processor: TranscriptPostProcessor
    ) async throws -> PipelineRun {
        let clock = ContinuousClock()
        let metrics = LibriSpeechStreamingMetrics()
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
                    let startedAt = librispeechSeconds(
                        replayStarted.duration(to: clock.now)
                    )
                    await polisher.consumeStableSegment(stableRange)
                    let finishedAt = librispeechSeconds(
                        replayStarted.duration(to: clock.now)
                    )
                    await metrics.record(
                        startedAt: startedAt,
                        finishedAt: finishedAt
                    )
                }
            )
            let rawCompletedAt = librispeechSeconds(
                replayStarted.duration(to: clock.now)
            )
            let result = await polisher.finalize(rawTranscript: rawTranscript)
            return PipelineCompletion(
                result: result,
                rawCompletedAt: rawCompletedAt,
                finalCompletedAt: librispeechSeconds(
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
                try await clock.sleep(
                    until: replayStarted.advanced(
                        by: .seconds(sourceElapsed / replaySpeed)
                    )
                )
            }
            continuation.yield(
                LiveAudioChunk(mono16kSamples: Array(samples[offset..<end]))
            )
            offset = end
        }

        let releasedAt = librispeechSeconds(
            replayStarted.duration(to: clock.now)
        )
        continuation.finish()
        let completion = try await pipelineTask.value
        let stableMetrics = await metrics.snapshot(releasedAt: releasedAt)

        return PipelineRun(
            rawTranscript: completion.result.rawTranscript,
            polishedTranscript: completion.result.transcript,
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
            stableMetrics: stableMetrics
        )
    }

    private func makeFixtures(
        datasetRoot: URL,
        count: Int,
        minimumDuration: Double,
        seed: UInt64
    ) throws -> [Fixture] {
        let references = try loadReferences(from: datasetRoot)
        let audioURLs = try files(withExtension: "flac", below: datasetRoot)
            .sorted { lhs, rhs in
                let lhsID = lhs.deletingPathExtension().lastPathComponent
                let rhsID = rhs.deletingPathExtension().lastPathComponent
                let lhsRank = deterministicRank(id: lhsID, seed: seed)
                let rhsRank = deterministicRank(id: rhsID, seed: seed)
                return lhsRank == rhsRank ? lhsID < rhsID : lhsRank < rhsRank
            }

        var fixtures: [Fixture] = []
        for audioURL in audioURLs {
            let id = audioURL.deletingPathExtension().lastPathComponent
            guard let reference = references[id] else { continue }
            let file = try AVAudioFile(forReading: audioURL)
            let sampleRate = file.processingFormat.sampleRate
            guard sampleRate > 0 else { continue }
            let duration = Double(file.length) / sampleRate
            guard duration >= minimumDuration else { continue }

            fixtures.append(
                Fixture(
                    id: id,
                    audioURL: audioURL,
                    reference: reference,
                    audioDuration: duration
                )
            )
            if fixtures.count == count { break }
        }

        guard fixtures.count == count else {
            throw NSError(
                domain: "Wordmate.LibriSpeechBenchmark",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Only found \(fixtures.count) aligned clips at least \(minimumDuration)s long"
                ]
            )
        }
        return fixtures
    }

    private func loadReferences(from root: URL) throws -> [String: String] {
        let transcriptFiles = try files(withExtension: "txt", below: root)
            .filter { $0.lastPathComponent.hasSuffix(".trans.txt") }
        var references: [String: String] = [:]

        for url in transcriptFiles {
            let contents = try String(contentsOf: url, encoding: .utf8)
            for line in contents.split(whereSeparator: { $0.isNewline }) {
                let fields = line.split(
                    maxSplits: 1,
                    whereSeparator: { $0.isWhitespace }
                )
                guard fields.count == 2 else { continue }
                references[String(fields[0])] = String(fields[1])
            }
        }
        return references
    }

    private func files(withExtension pathExtension: String, below root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        var matches: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == pathExtension {
            matches.append(url)
        }
        return matches
    }

    private func deterministicRank(id: String, seed: UInt64) -> UInt64 {
        var hash = UInt64(1_469_598_103_934_665_603) ^ seed
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        // FNV alone keeps neighboring LibriSpeech utterance IDs correlated.
        // A SplitMix64 finalizer gives the rank a stable avalanche so the
        // cohort spans speakers and chapters instead of selecting ID runs.
        hash ^= hash >> 30
        hash &*= 0xBF58_476D_1CE4_E5B9
        hash ^= hash >> 27
        hash &*= 0x94D0_49BB_1331_11EB
        hash ^= hash >> 31
        return hash
    }

    private func normalizedWords(_ text: String) -> [String] {
        // The production pipeline writes spelled-out numbers as numerals;
        // LibriSpeech references spell them out. Score content, not notation.
        SpokenNumberFormatter.format(text).lowercased().split { character in
            !character.isLetter && !character.isNumber
        }.map(String.init)
    }

    private func errorCounts(expected: [String], actual: [String]) -> ErrorCounts {
        let rowCount = expected.count + 1
        let columnCount = actual.count + 1
        var distances = Array(
            repeating: Array(repeating: 0, count: columnCount),
            count: rowCount
        )

        for row in 0..<rowCount { distances[row][0] = row }
        for column in 0..<columnCount { distances[0][column] = column }

        if !expected.isEmpty, !actual.isEmpty {
            for row in 1..<rowCount {
                for column in 1..<columnCount {
                    if expected[row - 1] == actual[column - 1] {
                        distances[row][column] = distances[row - 1][column - 1]
                    } else {
                        distances[row][column] = min(
                            distances[row - 1][column - 1] + 1,
                            distances[row - 1][column] + 1,
                            distances[row][column - 1] + 1
                        )
                    }
                }
            }
        }

        var counts = ErrorCounts()
        var row = expected.count
        var column = actual.count
        while row > 0 || column > 0 {
            if row > 0,
               column > 0,
               expected[row - 1] == actual[column - 1],
               distances[row][column] == distances[row - 1][column - 1] {
                row -= 1
                column -= 1
            } else if row > 0,
                      column > 0,
                      distances[row][column] == distances[row - 1][column - 1] + 1 {
                counts.substitutions += 1
                row -= 1
                column -= 1
            } else if row > 0,
                      distances[row][column] == distances[row - 1][column] + 1 {
                counts.deletions += 1
                row -= 1
            } else {
                counts.insertions += 1
                column -= 1
            }
        }
        return counts
    }

    private struct AggregateMetrics {
        let referenceWords: Int
        let rawErrors: ErrorCounts
        let polishedErrors: ErrorCounts
        let totalAudioDuration: Double

        var rawWER: Double {
            Double(rawErrors.total) / Double(referenceWords)
        }

        var polishedWER: Double {
            Double(polishedErrors.total) / Double(referenceWords)
        }
    }

    private func aggregateMetrics(_ results: [SampleResult]) -> AggregateMetrics {
        AggregateMetrics(
            referenceWords: results.reduce(0) { $0 + $1.referenceWordCount },
            rawErrors: results.reduce(ErrorCounts()) { $0 + $1.rawErrors },
            polishedErrors: results.reduce(ErrorCounts()) { $0 + $1.polishedErrors },
            totalAudioDuration: results.reduce(0) { $0 + $1.fixture.audioDuration }
        )
    }

    private func percentile(_ values: [Double], _ percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = min(1, max(0, percentile)) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        guard lower != upper else { return sorted[lower] }
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    private func makeReport(
        results: [SampleResult],
        datasetConfiguration: String,
        datasetSplit: String,
        minimumDuration: Double,
        seed: UInt64,
        replaySpeed: Double,
        parakeetPreparationDuration: Double,
        qwenPreparationDuration: Double,
        warmupDuration: Double
    ) -> String {
        let aggregate = aggregateMetrics(results)
        let improved = results.count(where: { $0.errorDelta < 0 })
        let unchanged = results.count(where: { $0.errorDelta == 0 })
        let worsened = results.count(where: { $0.errorDelta > 0 })
        let releaseLatencies = results.map(\.releaseToFinalDuration)
        let rawLatencies = results.map(\.releaseToRawDuration)
        let postLatencies = results.map(\.rawToFinalDuration)
        let clipRawWERs = results.map(\.rawWER)
        let clipPolishedWERs = results.map(\.polishedWER)
        let stableCallbacks = results.reduce(0) { $0 + $1.stableMetrics.callbackCount }
        let hiddenCallbacks = results.reduce(0) {
            $0 + $1.stableMetrics.finishedBeforeRelease
        }
        let hiddenQwenSeconds = results.reduce(0) {
            $0 + $1.stableMetrics.workBeforeRelease
        }
        let uniqueSpeakers = Set(results.map {
            $0.fixture.id.split(separator: "-").first.map(String.init) ?? "unknown"
        }).count
        let generatedAt = ISO8601DateFormatter().string(from: Date())
        let qwenErrorDelta = aggregate.polishedErrors.total - aggregate.rawErrors.total
        let qwenDeletionDelta = aggregate.polishedErrors.deletions
            - aggregate.rawErrors.deletions
        let isOther = datasetSplit == "test-other"
        let speechDescription = isOther
            ? "acoustically challenging read speech"
            : "clean read speech"

        var lines: [String] = [
            "# Wordmate LibriSpeech \(datasetSplit) benchmark — \(results.count) recordings",
            "",
            "> Generated by `LibriSpeechBenchmarkTests` on \(generatedAt).",
            "",
            "## Scope",
            "",
            "- Dataset: [LibriSpeech ASR](https://huggingface.co/datasets/openslr/librispeech_asr), `\(datasetConfiguration)` configuration, `test` split (`\(datasetSplit)`).",
            "- Source archive: [OpenSLR SLR12](https://www.openslr.org/12), licensed CC BY 4.0.",
            "- Cohort: \(results.count) deterministic recordings from \(uniqueSpeakers) speakers, each at least \(format(minimumDuration)) seconds.",
            "- Selection: all file IDs are ranked with seeded FNV-1a plus a SplitMix64 avalanche (`\(seed)`), then the first eligible recordings are used. The complete cohort appears below.",
            "- Pipeline: production cumulative Parakeet TDT v3 streaming, final full-audio Parakeet pass, Qwen3 0.6B 4-bit post-processing, and production reconciliation/safety checks.",
            "- Playback: \(replaySpeed == 1 ? "real-time (1×)" : "\(format(replaySpeed))×; 0 means immediate delivery"). Model preparation and one warm-up recording are excluded from per-recording latency.",
            "- WER normalization: Unicode lowercase words containing letters or numbers; punctuation is ignored. This is Wordmate's transparent test normalization, not a claim of direct comparability with every published LibriSpeech score.",
            "",
            "## Environment",
            "",
            "| Item | Value |",
            "| --- | --- |",
            "| macOS | \(markdown(ProcessInfo.processInfo.operatingSystemVersionString)) |",
            "| Chip | \(markdown(sysctlString("machdep.cpu.brand_string") ?? "Unknown")) |",
            "| Mac model | \(markdown(sysctlString("hw.model") ?? "Unknown")) |",
            "| Architecture | \(benchmarkArchitecture) |",
            "| Logical CPU cores | \(ProcessInfo.processInfo.processorCount) |",
            "| Memory | \(format(Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824)) GiB |",
            "| Parakeet preparation | \(format(parakeetPreparationDuration)) s |",
            "| Qwen preparation | \(format(qwenPreparationDuration)) s |",
            "| Inference warm-up | \(format(warmupDuration)) s |",
            "",
            "## Headline results",
            "",
            "| Metric | Raw Parakeet | After Qwen | Delta |",
            "| --- | ---: | ---: | ---: |",
            "| Corpus WER | \(percent(aggregate.rawWER)) | \(percent(aggregate.polishedWER)) | \(signedPercentagePoints(aggregate.polishedWER - aggregate.rawWER)) |",
            "| Total word errors | \(aggregate.rawErrors.total) | \(aggregate.polishedErrors.total) | \(signedInteger(aggregate.polishedErrors.total - aggregate.rawErrors.total)) |",
            "| Substitutions | \(aggregate.rawErrors.substitutions) | \(aggregate.polishedErrors.substitutions) | \(signedInteger(aggregate.polishedErrors.substitutions - aggregate.rawErrors.substitutions)) |",
            "| Deletions | \(aggregate.rawErrors.deletions) | \(aggregate.polishedErrors.deletions) | \(signedInteger(aggregate.polishedErrors.deletions - aggregate.rawErrors.deletions)) |",
            "| Insertions | \(aggregate.rawErrors.insertions) | \(aggregate.polishedErrors.insertions) | \(signedInteger(aggregate.polishedErrors.insertions - aggregate.rawErrors.insertions)) |",
            "| Median per-clip WER | \(percent(percentile(clipRawWERs, 0.5))) | \(percent(percentile(clipPolishedWERs, 0.5))) | — |",
            "| P90 per-clip WER | \(percent(percentile(clipRawWERs, 0.9))) | \(percent(percentile(clipPolishedWERs, 0.9))) | — |",
            "",
            "The cohort contains **\(aggregate.referenceWords) reference words** across **\(format(aggregate.totalAudioDuration / 60)) minutes** of audio. Qwen improved \(recordingCount(improved)), left \(recordingCount(unchanged)) unchanged by word-error count, and worsened \(recordingCount(worsened)).",
            "",
            "## User-perceived latency",
            "",
            "Latency is measured from release of Fn (the end of each recording) until the final polished transcript is available.",
            "",
            "| Metric | Release → raw | Raw → polished | Release → final |",
            "| --- | ---: | ---: | ---: |",
            "| Median | \(secondsValue(percentile(rawLatencies, 0.5))) | \(secondsValue(percentile(postLatencies, 0.5))) | \(secondsValue(percentile(releaseLatencies, 0.5))) |",
            "| P90 | \(secondsValue(percentile(rawLatencies, 0.9))) | \(secondsValue(percentile(postLatencies, 0.9))) | \(secondsValue(percentile(releaseLatencies, 0.9))) |",
            "| P95 | \(secondsValue(percentile(rawLatencies, 0.95))) | \(secondsValue(percentile(postLatencies, 0.95))) | \(secondsValue(percentile(releaseLatencies, 0.95))) |",
            "| Maximum | \(secondsValue(rawLatencies.max() ?? 0)) | \(secondsValue(postLatencies.max() ?? 0)) | \(secondsValue(releaseLatencies.max() ?? 0)) |",
            "",
            "The streaming path emitted \(stableCallbacks) stable-segment callbacks; \(hiddenCallbacks) finished before release, hiding \(format(hiddenQwenSeconds)) seconds of measured Qwen callback work while speech was still in progress.",
            "",
            "## Post-processing impact",
            "",
            "| Outcome | Recordings |",
            "| --- | ---: |",
            "| Fewer word errors | \(improved) |",
            "| Same word-error count | \(unchanged) |",
            "| More word errors | \(worsened) |",
            "",
            worsened == 0 ? "## Findings" : "## Findings and required correction",
            "",
            "1. **Raw Parakeet reaches \(percent(aggregate.rawWER)) WER on \(speechDescription).** The cohort contains \(aggregate.referenceWords) reference words.",
            worsened == 0
                ? "2. **Qwen is lossless on this fluent cohort.** It changed the cohort by \(signedInteger(qwenErrorDelta)) word errors, moved corpus WER by \(signedPercentagePoints(aggregate.polishedWER - aggregate.rawWER)), and worsened no recording."
                : "2. **Qwen is not lossless enough on fluent speech.** It changed the cohort by \(signedInteger(qwenErrorDelta)) word errors and moved corpus WER by \(signedPercentagePoints(aggregate.polishedWER - aggregate.rawWER)).",
            worsened == 0
                ? "3. **No valuable lexical information was lost.** Substitutions changed by \(signedInteger(aggregate.polishedErrors.substitutions - aggregate.rawErrors.substitutions)), deletions by \(signedInteger(qwenDeletionDelta)), and insertions by \(signedInteger(aggregate.polishedErrors.insertions - aggregate.rawErrors.insertions)). Punctuation improvements are intentionally invisible to WER."
                : "3. **The failure mode is deletion, not hallucination.** Qwen added \(signedInteger(qwenDeletionDelta)) deletions, while substitutions changed by \(signedInteger(aggregate.polishedErrors.substitutions - aggregate.rawErrors.substitutions)) and insertions by \(signedInteger(aggregate.polishedErrors.insertions - aggregate.rawErrors.insertions)). It removed legitimate parenthetical phrases, modifiers, and unfamiliar terms that resembled speech repairs.",
            worsened == 0
                ? "4. **The language-agnostic safety projection is doing its job.** A fluent source with no immediate repeated span receives no lexical-deletion budget. When repeated speech is present, Qwen still decides whether the repetition is accidental and may clean a nearby false start."
                : "4. **The current safety allowance is too permissive.** The projection permits non-repetition deletions that can remove valid content. Tighten this language-agnostically while keeping Qwen responsible for deciding whether repeated speech is accidental.",
            worsened == 0
                ? "5. **Release latency remains practical on this machine.** Final text arrived in a median \(secondsValue(percentile(releaseLatencies, 0.5))) after release, with P95 \(secondsValue(percentile(releaseLatencies, 0.95)))."
                : "5. **Latency is already strong on this machine.** Final text arrived in a median \(secondsValue(percentile(releaseLatencies, 0.5))) after release, with P95 \(secondsValue(percentile(releaseLatencies, 0.95))). Quality safety—not speed—is the next priority.",
            worsened == 0
                ? "6. **The former regressions are permanent acceptance fixtures.** Future prompt or guard changes must keep them lossless and retain the established heavy-stutter improvement before shipping."
                : "6. **Make these regressions permanent acceptance fixtures.** Any guard change should pass all regressed LibriSpeech IDs below and retain the established heavy-stutter improvement before it ships.",
            "",
        ]

        let regressions = results
            .filter { $0.errorDelta > 0 }
            .sorted {
                $0.errorDelta == $1.errorDelta
                    ? $0.fixture.id < $1.fixture.id
                    : $0.errorDelta > $1.errorDelta
            }
        if regressions.isEmpty {
            lines.append("No clip gained word errors after post-processing in this cohort.")
        } else {
            lines.append("Largest Qwen regressions (useful for prompt and safety-policy review):")
            lines.append("")
            lines.append("| ID | Raw errors | Polished errors | Added errors |")
            lines.append("| --- | ---: | ---: | ---: |")
            for result in regressions.prefix(10) {
                lines.append(
                    "| \(result.fixture.id) | \(result.rawErrors.total) | \(result.polishedErrors.total) | +\(result.errorDelta) |"
                )
            }
        }

        lines.append(contentsOf: [
            "",
            "## Hardest raw-ASR recordings",
            "",
            "| ID | Duration | Words | Raw WER | Polished WER |",
            "| --- | ---: | ---: | ---: | ---: |",
        ])
        for result in results.sorted(by: {
            $0.rawWER == $1.rawWER
                ? $0.fixture.id < $1.fixture.id
                : $0.rawWER > $1.rawWER
        }).prefix(10) {
            lines.append(
                "| \(result.fixture.id) | \(secondsValue(result.fixture.audioDuration)) | \(result.referenceWordCount) | \(percent(result.rawWER)) | \(percent(result.polishedWER)) |"
            )
        }

        lines.append(contentsOf: [
            "",
            "## Selected diagnostic transcripts",
            "",
            regressions.isEmpty
                ? "These are the five clips with the largest absolute post-processing error change."
                : "These are all clips whose word-error count increased after post-processing, ordered by regression size.",
            "",
        ])
        let diagnosticResults: ArraySlice<SampleResult>
        if regressions.isEmpty {
            diagnosticResults = results.sorted {
                abs($0.errorDelta) == abs($1.errorDelta)
                    ? $0.fixture.id < $1.fixture.id
                    : abs($0.errorDelta) > abs($1.errorDelta)
            }.prefix(5)
        } else {
            diagnosticResults = regressions[regressions.startIndex...]
        }
        for result in diagnosticResults {
            lines.append("### \(result.fixture.id)")
            lines.append("")
            lines.append("- Reference: \(markdown(result.fixture.reference))")
            lines.append("- Raw: \(markdown(result.rawTranscript))")
            lines.append("- Polished: \(markdown(result.polishedTranscript))")
            lines.append("")
        }

        lines.append(contentsOf: [
            "## All recording results",
            "",
            "`Δ errors` is polished errors minus raw errors, so a negative value is an improvement.",
            "",
            "| # | LibriSpeech ID | Audio | Words | Raw S/D/I | Raw WER | Polished S/D/I | Polished WER | Δ errors | Release → final | Stable callbacks |",
            "| ---: | --- | ---: | ---: | --- | ---: | --- | ---: | ---: | ---: | ---: |",
        ])
        for result in results {
            lines.append(
                "| \(result.index) | \(result.fixture.id) | \(format(result.fixture.audioDuration)) s | \(result.referenceWordCount) | \(errorTriplet(result.rawErrors)) | \(percent(result.rawWER)) | \(errorTriplet(result.polishedErrors)) | \(percent(result.polishedWER)) | \(signedInteger(result.errorDelta)) | \(format(result.releaseToFinalDuration)) s | \(result.stableMetrics.callbackCount) |"
            )
        }

        lines.append(contentsOf: [
            "",
            "## Limitations",
            "",
            isOther
                ? "- `test-other` is the more acoustically challenging LibriSpeech evaluation split, but it is still read-audiobook English rather than spontaneous dictation, technical speech, or real-world microphone noise."
                : "- `test-clean` contains controlled read-audiobook English. It is a strong reproducible regression baseline, but it is easier than spontaneous dictation, accents outside its distribution, technical names, noisy microphones, and code-heavy speech.",
            "- Performance was measured on the Mac described above. A 16 GB base machine must be benchmarked separately before publishing device-wide latency claims.",
            "- WER deliberately ignores punctuation and capitalization. Qwen's formatting improvements are visible in transcripts but do not receive artificial credit in the accuracy score.",
            "",
            "## Reproduce",
            "",
            "From the `local-transcriber` directory:",
            "",
            "```sh",
            "WORDMATE_LIBRISPEECH_SPLIT=\(datasetSplit) \\",
            "WORDMATE_LIBRISPEECH_SAMPLE_COUNT=\(results.count) \\",
            "zsh scripts/run-librispeech-benchmark.sh",
            "```",
            "",
            "The script caches the official archive under `/private/tmp/wordmate-librispeech`, verifies its published MD5 checksum, selects the same cohort, and replaces this report with the new run.",
            "",
        ])
        return lines.joined(separator: "\n")
    }

    private func errorTriplet(_ counts: ErrorCounts) -> String {
        "\(counts.substitutions)/\(counts.deletions)/\(counts.insertions)"
    }

    private func percent(_ ratio: Double) -> String {
        "\(format(ratio * 100))%"
    }

    private func signedPercentagePoints(_ ratio: Double) -> String {
        let value = ratio * 100
        return "\(value > 0 ? "+" : "")\(format(value)) pp"
    }

    private func signedInteger(_ value: Int) -> String {
        value > 0 ? "+\(value)" : String(value)
    }

    private func recordingCount(_ value: Int) -> String {
        "\(value) recording\(value == 1 ? "" : "s")"
    }

    private func secondsValue(_ value: Double) -> String {
        "\(format(value)) s"
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func markdown(_ text: String) -> String {
        text
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        return String(cString: buffer)
    }
}

private actor LibriSpeechStreamingMetrics {
    struct Snapshot: Sendable {
        let callbackCount: Int
        let finishedBeforeRelease: Int
        let workBeforeRelease: Double
        let workAfterRelease: Double
    }

    private struct Callback: Sendable {
        let startedAt: Double
        let finishedAt: Double
    }

    private var callbacks: [Callback] = []

    func record(startedAt: Double, finishedAt: Double) {
        callbacks.append(
            Callback(startedAt: startedAt, finishedAt: finishedAt)
        )
    }

    func snapshot(releasedAt: Double) -> Snapshot {
        Snapshot(
            callbackCount: callbacks.count,
            finishedBeforeRelease: callbacks.count(where: {
                $0.finishedAt <= releasedAt
            }),
            workBeforeRelease: callbacks.reduce(0) { total, callback in
                total + max(
                    0,
                    min(callback.finishedAt, releasedAt) - callback.startedAt
                )
            },
            workAfterRelease: callbacks.reduce(0) { total, callback in
                total + max(
                    0,
                    callback.finishedAt - max(callback.startedAt, releasedAt)
                )
            }
        )
    }
}

private func librispeechSeconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
}

private var benchmarkArchitecture: String {
    #if arch(arm64)
    return "arm64"
    #elseif arch(x86_64)
    return "x86_64"
    #else
    return "unknown"
    #endif
}
