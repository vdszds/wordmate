import Foundation
import XCTest
@testable import LocalTranscriber

/// Scores Wordmate's post-processing against reference transcripts of real
/// dictations (for example Wispr Flow output). Unlike the WER benchmarks this
/// compares the *formatted* text: punctuation, casing, paragraphs, numerals
/// and disfluency removal all count.
///
/// Stage 1 (`WORDMATE_DICTATION_SET_MODE=capture`) replays each recording
/// through the production streaming pipeline at real-time speed and caches the
/// stable segments Parakeet committed plus the final raw transcript. Stage 2
/// (`replay`, the default) feeds those cached segments through the polisher so
/// prompt and model iterations run at Qwen speed with production chunking.
final class DictationSetBenchmarkTests: XCTestCase {
    private struct Fixture: Decodable {
        let name: String
        let audioPath: String
        let referencePath: String
    }

    private struct CapturedSegment: Codable {
        let source: String
        let precedingContext: String
        let followingContext: String
    }

    private struct CapturedRecording: Codable {
        let name: String
        let audioDuration: Double
        let rawTranscript: String
        let segments: [CapturedSegment]
        var timeline: TimedTranscript?
    }

    private actor SegmentRecorder {
        private(set) var segments: [CapturedSegment] = []

        func append(_ range: StreamingStableRange) {
            segments.append(
                CapturedSegment(
                    source: range.source,
                    precedingContext: range.precedingContext,
                    followingContext: range.followingContext
                )
            )
        }
    }

    func testDictationSetAgainstReferenceTranscripts() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WORDMATE_RUN_DICTATION_SET"] == "1" else {
            throw XCTSkip("Run explicitly with WORDMATE_RUN_DICTATION_SET=1")
        }
        guard let manifestPath = environment["WORDMATE_DICTATION_SET_MANIFEST"] else {
            XCTFail("WORDMATE_DICTATION_SET_MANIFEST must point to a JSON manifest")
            return
        }
        let cacheDirectory = URL(
            fileURLWithPath: environment["WORDMATE_DICTATION_SET_CACHE"]
                ?? "/private/tmp/wordmate-dictation-set/cache"
        )
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        let mode = environment["WORDMATE_DICTATION_SET_MODE"] ?? "replay"
        let replaySpeed = Double(environment["WORDMATE_DICTATION_SET_REPLAY_SPEED"] ?? "1") ?? 1
        let includeWhole = environment["WORDMATE_DICTATION_SET_WHOLE"] == "1"
        let printTranscripts = environment["WORDMATE_BENCHMARK_PRINT_TRANSCRIPTS"] == "1"
        let onlyNames = environment["WORDMATE_DICTATION_SET_ONLY"]?
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? []

        let manifestData = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
        var fixtures = try JSONDecoder().decode([Fixture].self, from: manifestData)
        if !onlyNames.isEmpty {
            fixtures = fixtures.filter { onlyNames.contains($0.name) }
        }

        let runner = ModelRunner()
        let processor = TranscriptPostProcessor()
        var parakeetPrepared = false
        let clock = ContinuousClock()
        if mode != "capture" {
            let started = clock.now
            try await processor.prepare(.qwen3_0_6b)
            print("DICTATION_QWEN_PREPARE_SECONDS=\(format(benchmarkSeconds(started.duration(to: clock.now))))")
        }

        var totals = Totals()
        for fixture in fixtures {
            let cacheURL = cacheDirectory.appendingPathComponent("\(fixture.name).json")
            let captured: CapturedRecording
            if mode != "capture",
               let data = try? Data(contentsOf: cacheURL),
               let cached = try? JSONDecoder().decode(CapturedRecording.self, from: data),
               cached.timeline != nil {
                captured = cached
            } else {
                if !parakeetPrepared {
                    try await runner.prepare(.parakeet)
                    parakeetPrepared = true
                }
                captured = try await capture(
                    fixture: fixture,
                    replaySpeed: replaySpeed,
                    runner: runner
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(captured).write(to: cacheURL)
            }

            let reference = try String(
                contentsOf: URL(fileURLWithPath: fixture.referencePath),
                encoding: .utf8
            )
            let rawScore = TranscriptScore(hypothesis: captured.rawTranscript, reference: reference)
            totals.add(raw: rawScore)

            var line = "DICTATION_SAMPLE name=\(fixture.name)"
                + " audio=\(format(captured.audioDuration))"
                + " segments=\(captured.segments.count)"
                + " pauses=\(captured.timeline?.pauses.count ?? -1)"
                + " ref_words=\(rawScore.referenceWords)"
                + " raw_cer=\(format(rawScore.formattedCER))"
                + " raw_wer=\(format(rawScore.contentWER))"

            var streamingOutput: String?
            var wholeOutput: String?
            if mode != "capture" {
                let started = clock.now
                let result = await replay(captured, processor: processor)
                let elapsed = benchmarkSeconds(started.duration(to: clock.now))
                let records = await processor.drainCallRecords()
                let rejected = records.filter { $0.outcome != .accepted }.count
                if environment["WORDMATE_DICTATION_SET_PRINT_REJECTED"] == "1" {
                    for record in records where record.outcome != .accepted {
                        print("DICTATION_REJECTED name=\(fixture.name) stage=\(record.stage.rawValue) outcome=\(record.outcome.rawValue)")
                        print("  SOURCE: \(record.source)")
                        print("  OUTPUT: \(record.output)")
                    }
                }
                let score = TranscriptScore(hypothesis: result.transcript, reference: reference)
                totals.add(polished: score)
                streamingOutput = result.transcript
                line += " polished_cer=\(format(score.formattedCER))"
                    + " polished_wer=\(format(score.contentWER))"
                    + " sentence_f1=\(format(score.sentenceF1))"
                    + " comma_f1=\(format(score.commaF1))"
                    + " paragraph_f1=\(format(score.paragraphF1))"
                    + " casing=\(format(score.casingAgreement))"
                    + " numbers=\(format(score.numberRecall))"
                    + " calls=\(records.count) rejected=\(rejected)"
                    + " strategy=\(String(describing: result.finalizationDiagnostics.strategy))"
                    + " reason=\(String(describing: result.finalizationDiagnostics.fullPassReason))"
                    + " seconds=\(format(elapsed))"

                if includeWhole {
                    let wholeStarted = clock.now
                    let polished: String
                    do {
                        let formatted = SpokenNumberFormatter.format(
                            try await processor.polish(
                                captured.rawTranscript,
                                using: .qwen3_0_6b
                            )
                        )
                        polished = TranscriptPolishPolicy.applyingParagraphBreaks(
                            to: formatted,
                            startingAt: ParagraphPlanner.paragraphStarts(in: formatted)
                        )
                    } catch {
                        polished = captured.rawTranscript
                    }
                    let wholeElapsed = benchmarkSeconds(wholeStarted.duration(to: clock.now))
                    let wholeRecords = await processor.drainCallRecords()
                    let wholeRejected = wholeRecords.filter { $0.outcome != .accepted }.count
                    let wholeScore = TranscriptScore(hypothesis: polished, reference: reference)
                    totals.add(whole: wholeScore)
                    wholeOutput = polished
                    line += " whole_cer=\(format(wholeScore.formattedCER))"
                        + " whole_wer=\(format(wholeScore.contentWER))"
                        + " whole_sentence_f1=\(format(wholeScore.sentenceF1))"
                        + " whole_paragraph_f1=\(format(wholeScore.paragraphF1))"
                        + " whole_calls=\(wholeRecords.count) whole_rejected=\(wholeRejected)"
                        + " whole_seconds=\(format(wholeElapsed))"
                }
            }
            print(line)

            if printTranscripts {
                print("DICTATION_RAW_BEGIN \(fixture.name)")
                print(captured.rawTranscript)
                print("DICTATION_RAW_END")
                if let streamingOutput {
                    print("DICTATION_STREAMING_BEGIN \(fixture.name)")
                    print(streamingOutput)
                    print("DICTATION_STREAMING_END")
                }
                if let wholeOutput {
                    print("DICTATION_WHOLE_BEGIN \(fixture.name)")
                    print(wholeOutput)
                    print("DICTATION_WHOLE_END")
                }
            }
        }

        print(totals.summaryLine())
    }

    // MARK: - Capture

    private func capture(
        fixture: Fixture,
        replaySpeed: Double,
        runner: ModelRunner
    ) async throws -> CapturedRecording {
        let samples = try AudioSampleLoader.loadMono16k(
            from: URL(fileURLWithPath: fixture.audioPath)
        )
        let audioDuration = Double(samples.count) / AudioSampleLoader.sampleRate
        let recorder = SegmentRecorder()
        let clock = ContinuousClock()

        var capturedContinuation: AsyncStream<LiveAudioChunk>.Continuation?
        let stream = AsyncStream<LiveAudioChunk>(bufferingPolicy: .unbounded) {
            capturedContinuation = $0
        }
        guard let continuation = capturedContinuation else {
            throw LocalTranscriberError.audioConversionFailed
        }

        let replayStarted = clock.now
        let pipelineTask = Task(priority: .userInitiated) {
            try await runner.transcribeStreamingWithTimings(stream, using: .parakeet) { range in
                await recorder.append(range)
            }
        }

        let framesPerChunk = Int(AudioSampleLoader.sampleRate / 10)
        var offset = 0
        while offset < samples.count {
            let end = min(samples.count, offset + framesPerChunk)
            if replaySpeed > 0 {
                let sourceElapsed = Double(end) / AudioSampleLoader.sampleRate
                let deadline = replayStarted.advanced(by: .seconds(sourceElapsed / replaySpeed))
                try await clock.sleep(until: deadline)
            }
            continuation.yield(LiveAudioChunk(mono16kSamples: Array(samples[offset..<end])))
            offset = end
        }
        continuation.finish()
        let timed = try await pipelineTask.value
        return CapturedRecording(
            name: fixture.name,
            audioDuration: audioDuration,
            rawTranscript: TranscriptCleaner.clean(timed.transcript),
            segments: await recorder.segments,
            timeline: timed
        )
    }

    // MARK: - Replay

    private func replay(
        _ captured: CapturedRecording,
        processor: TranscriptPostProcessor
    ) async -> LiveDictationResult {
        let polisher = StreamingTranscriptPolisher(
            isEnabled: true,
            model: .qwen3_0_6b,
            processor: processor
        )
        for segment in captured.segments {
            await polisher.consumeStableSegment(
                StreamingStableRange(
                    source: segment.source,
                    precedingContext: segment.precedingContext,
                    followingContext: segment.followingContext
                )
            )
            // Production keeps up with five-second checkpoints; replaying at
            // Qwen speed must not let the queue fold segments into the final pass.
            await polisher.waitForQueuedWork()
        }
        return await polisher.finalize(rawTranscript: captured.rawTranscript)
    }

    // MARK: - Scoring

    private struct Totals {
        var referenceCharacters = 0
        var referenceWords = 0
        var rawFormattedEdits = 0
        var rawContentEdits = 0
        var polishedFormattedEdits = 0
        var polishedContentEdits = 0
        var wholeFormattedEdits = 0
        var wholeContentEdits = 0
        var polishedCount = 0
        var wholeCount = 0
        var sentenceF1Sum = 0.0
        var commaF1Sum = 0.0
        var paragraphF1Sum = 0.0
        var casingSum = 0.0
        var numbersSum = 0.0
        var wholeSentenceF1Sum = 0.0
        var wholeParagraphF1Sum = 0.0

        mutating func add(raw: TranscriptScore) {
            referenceCharacters += raw.referenceCharacters
            referenceWords += raw.referenceWords
            rawFormattedEdits += raw.formattedEdits
            rawContentEdits += raw.contentEdits
        }

        mutating func add(polished: TranscriptScore) {
            polishedFormattedEdits += polished.formattedEdits
            polishedContentEdits += polished.contentEdits
            polishedCount += 1
            sentenceF1Sum += polished.sentenceF1
            commaF1Sum += polished.commaF1
            paragraphF1Sum += polished.paragraphF1
            casingSum += polished.casingAgreement
            numbersSum += polished.numberRecall
        }

        mutating func add(whole: TranscriptScore) {
            wholeFormattedEdits += whole.formattedEdits
            wholeContentEdits += whole.contentEdits
            wholeCount += 1
            wholeSentenceF1Sum += whole.sentenceF1
            wholeParagraphF1Sum += whole.paragraphF1
        }

        func summaryLine() -> String {
            func ratio(_ edits: Int, _ total: Int) -> Double {
                total == 0 ? 0 : Double(edits) / Double(total)
            }
            var line = "DICTATION_TOTAL ref_chars=\(referenceCharacters) ref_words=\(referenceWords)"
                + " raw_cer=\(formatValue(ratio(rawFormattedEdits, referenceCharacters)))"
                + " raw_wer=\(formatValue(ratio(rawContentEdits, referenceWords)))"
            if polishedCount > 0 {
                let count = Double(polishedCount)
                line += " polished_cer=\(formatValue(ratio(polishedFormattedEdits, referenceCharacters)))"
                    + " polished_wer=\(formatValue(ratio(polishedContentEdits, referenceWords)))"
                    + " sentence_f1=\(formatValue(sentenceF1Sum / count))"
                    + " comma_f1=\(formatValue(commaF1Sum / count))"
                    + " paragraph_f1=\(formatValue(paragraphF1Sum / count))"
                    + " casing=\(formatValue(casingSum / count))"
                    + " numbers=\(formatValue(numbersSum / count))"
            }
            if wholeCount > 0 {
                let count = Double(wholeCount)
                line += " whole_cer=\(formatValue(ratio(wholeFormattedEdits, referenceCharacters)))"
                    + " whole_wer=\(formatValue(ratio(wholeContentEdits, referenceWords)))"
                    + " whole_sentence_f1=\(formatValue(wholeSentenceF1Sum / count))"
                    + " whole_paragraph_f1=\(formatValue(wholeParagraphF1Sum / count))"
            }
            return line
        }
    }

    private func format(_ value: Double) -> String { formatValue(value) }
}

private func formatValue(_ value: Double) -> String {
    String(format: "%.3f", value)
}

private func benchmarkSeconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
}

/// Formatting-aware comparison of a hypothesis against a reference transcript.
struct TranscriptScore {
    /// Character error rate of the formatted text (case, punctuation and
    /// paragraph breaks all count) after whitespace normalisation.
    let formattedCER: Double
    /// Word error rate on lowercased, punctuation-free words. Measures
    /// disfluency removal and word retention; blind to formatting.
    let contentWER: Double
    /// F1 of sentence terminators placed after aligned words.
    let sentenceF1: Double
    /// F1 of commas, semicolons and colons placed after aligned words.
    let commaF1: Double
    /// F1 of line or paragraph breaks placed after aligned words.
    let paragraphF1: Double
    /// Share of aligned words whose surface form (casing, apostrophes) matches.
    let casingAgreement: Double
    /// Share of the reference's digit-bearing tokens present in the hypothesis.
    let numberRecall: Double
    let referenceCharacters: Int
    let referenceWords: Int
    let formattedEdits: Int
    let contentEdits: Int

    init(hypothesis: String, reference: String) {
        let referenceText = Array(TranscriptScore.normalizedFormatting(reference))
        let hypothesisText = Array(TranscriptScore.normalizedFormatting(hypothesis))
        formattedEdits = TranscriptScore.editDistance(hypothesisText, referenceText)
        referenceCharacters = referenceText.count
        formattedCER = referenceCharacters == 0 ? 0 : Double(formattedEdits) / Double(referenceCharacters)

        let referenceTokens = TranscriptScore.tokens(in: reference)
        let hypothesisTokens = TranscriptScore.tokens(in: hypothesis)
        let referenceWordList = referenceTokens.map(\.normalized)
        let hypothesisWordList = hypothesisTokens.map(\.normalized)
        contentEdits = TranscriptScore.editDistance(hypothesisWordList, referenceWordList)
        referenceWords = referenceWordList.count
        contentWER = referenceWords == 0 ? 0 : Double(contentEdits) / Double(referenceWords)

        let pairs = TranscriptScore.alignment(referenceWordList, hypothesisWordList)
        sentenceF1 = TranscriptScore.f1(
            pairs,
            reference: referenceTokens,
            hypothesis: hypothesisTokens,
            attribute: \.strongBoundaryAfter
        )
        commaF1 = TranscriptScore.f1(
            pairs,
            reference: referenceTokens,
            hypothesis: hypothesisTokens,
            attribute: \.commaAfter
        )
        paragraphF1 = TranscriptScore.f1(
            pairs,
            reference: referenceTokens,
            hypothesis: hypothesisTokens,
            attribute: \.paragraphAfter
        )
        if pairs.isEmpty {
            casingAgreement = 0
        } else {
            let matching = pairs.filter { referenceTokens[$0.0].text == hypothesisTokens[$0.1].text }.count
            casingAgreement = Double(matching) / Double(pairs.count)
        }

        let referenceNumbers = referenceTokens.map(\.normalized).filter { $0.contains(where: \.isNumber) }
        var hypothesisNumbers = hypothesisTokens.map(\.normalized).filter { $0.contains(where: \.isNumber) }
        if referenceNumbers.isEmpty {
            numberRecall = 1
        } else {
            var matched = 0
            for number in referenceNumbers {
                if let index = hypothesisNumbers.firstIndex(of: number) {
                    hypothesisNumbers.remove(at: index)
                    matched += 1
                }
            }
            numberRecall = Double(matched) / Double(referenceNumbers.count)
        }
    }

    struct Token {
        let text: String
        let normalized: String
        let strongBoundaryAfter: Bool
        let commaAfter: Bool
        let paragraphAfter: Bool
    }

    static func normalizedFormatting(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        let lines = result
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line -> String in
                line.split(whereSeparator: { $0 == " " }).joined(separator: " ")
            }
            .filter { !$0.isEmpty }
        result = lines.joined(separator: "\n")
        return result
    }

    static func tokens(in text: String) -> [Token] {
        let pattern = #"[\p{L}\p{N}]+(?:['’\-.,:/][\p{L}\p{N}]+)*%?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var result: [Token] = []
        result.reserveCapacity(matches.count)
        for (index, match) in matches.enumerated() {
            let word = nsText.substring(with: match.range)
            let gapStart = match.range.location + match.range.length
            let gapEnd = index + 1 < matches.count ? matches[index + 1].range.location : nsText.length
            let gap = nsText.substring(with: NSRange(location: gapStart, length: gapEnd - gapStart))
            let normalized = word
                .replacingOccurrences(of: "’", with: "'")
                .lowercased()
                .filter { $0.isLetter || $0.isNumber || $0 == "'" }
            guard !normalized.isEmpty else { continue }
            result.append(
                Token(
                    text: word.replacingOccurrences(of: "’", with: "'"),
                    normalized: normalized,
                    strongBoundaryAfter: gap.contains(where: { ".?!…".contains($0) }),
                    commaAfter: gap.contains(where: { ",;:".contains($0) }),
                    paragraphAfter: gap.contains("\n")
                )
            )
        }
        return result
    }

    static func alignment(_ reference: [String], _ hypothesis: [String]) -> [(Int, Int)] {
        let n = reference.count
        let m = hypothesis.count
        guard n > 0, m > 0 else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if reference[i] == hypothesis[j] {
                    table[i][j] = table[i + 1][j + 1] + 1
                } else {
                    table[i][j] = max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < n, j < m {
            if reference[i] == hypothesis[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    static func f1(
        _ pairs: [(Int, Int)],
        reference: [Token],
        hypothesis: [Token],
        attribute: KeyPath<Token, Bool>
    ) -> Double {
        var truePositives = 0
        var falsePositives = 0
        var falseNegatives = 0
        for (referenceIndex, hypothesisIndex) in pairs {
            let expected = reference[referenceIndex][keyPath: attribute]
            let actual = hypothesis[hypothesisIndex][keyPath: attribute]
            switch (expected, actual) {
            case (true, true): truePositives += 1
            case (false, true): falsePositives += 1
            case (true, false): falseNegatives += 1
            case (false, false): break
            }
        }
        let denominator = 2 * truePositives + falsePositives + falseNegatives
        return denominator == 0 ? 1 : Double(2 * truePositives) / Double(denominator)
    }

    static func editDistance<T: Equatable>(_ lhs: [T], _ rhs: [T]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        var current = Array(repeating: 0, count: rhs.count + 1)
        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                let cost = lhs[i - 1] == rhs[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }
}
