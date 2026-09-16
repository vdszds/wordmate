import Foundation
import XCTest
@testable import LocalTranscriber

/// Pushes raw Parakeet transcripts through the same sentence-level polishing
/// the streaming pipeline uses, without replaying audio, so prompt and model
/// variants can be compared in seconds. Run with:
///
///   WORDMATE_RUN_PROMPT_ITERATION=1 \
///   WORDMATE_PROMPT_ITERATION_MANIFEST=/path/manifest.json \
///   swift test --skip-build --filter PromptIterationBenchmarkTests
///
/// The manifest is a JSON array of {name, rawPath, referencePath}. Prompt and
/// model overrides come from the WORDMATE_* environment hooks.
final class PromptIterationBenchmarkTests: XCTestCase {
    private struct Fixture: Decodable {
        let name: String
        let rawPath: String
        let referencePath: String
    }

    func testRecordingsSentenceBySentence() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WORDMATE_RUN_PROMPT_ITERATION"] == "1" else {
            throw XCTSkip("Run explicitly with WORDMATE_RUN_PROMPT_ITERATION=1")
        }
        guard let manifestPath = environment["WORDMATE_PROMPT_ITERATION_MANIFEST"] else {
            XCTFail("WORDMATE_PROMPT_ITERATION_MANIFEST must point to a JSON manifest")
            return
        }
        let fixtures = try JSONDecoder().decode(
            [Fixture].self,
            from: Data(contentsOf: URL(fileURLWithPath: manifestPath))
        )

        let processor = TranscriptPostProcessor()
        try await processor.prepare(.qwen3_0_6b)
        let clock = ContinuousClock()

        var totalRaw = 0
        var totalPolished = 0
        var totalReference = 0
        for fixture in fixtures {
            let raw = TranscriptCleaner.clean(
                try String(contentsOfFile: fixture.rawPath, encoding: .utf8)
            )
            let reference = try String(contentsOfFile: fixture.referencePath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let sentences = StreamingTranscriptPolicy.sentenceSegments(
                in: raw,
                mergingSegmentsShorterThan: 4
            )
            let started = clock.now
            var outputs: [String] = []
            for (index, sentence) in sentences.enumerated() {
                let preceding = StreamingTranscriptPolicy.trailingContext(
                    of: sentences[..<index].joined(separator: " ")
                )
                let following = index + 1 < sentences.count
                    ? StreamingTranscriptPolicy.leadingContext(of: sentences[index + 1])
                    : ""
                outputs.append(
                    try await processor.polishStreamingSegment(
                        sentence,
                        precedingContext: preceding,
                        followingContext: following,
                        using: .qwen3_0_6b
                    )
                )
            }
            let polished = outputs.joined(separator: " ")
            let elapsed = started.duration(to: clock.now)
            let records = await processor.drainCallRecords()

            let referenceWords = normalizedWords(reference)
            let rawErrors = editDistance(normalizedWords(raw), referenceWords)
            let polishedErrors = editDistance(normalizedWords(polished), referenceWords)
            totalRaw += rawErrors
            totalPolished += polishedErrors
            totalReference += referenceWords.count

            let rejected = records.filter { $0.outcome != .accepted }.count
            print(
                "PROMPT_ITERATION_SAMPLE name=\(fixture.name) raw_errors=\(rawErrors) polished_errors=\(polishedErrors) "
                    + "calls=\(records.count) rejected=\(rejected) seconds=\(String(format: "%.2f", seconds(elapsed)))"
            )
            print("PROMPT_ITERATION_OUTPUT_BEGIN \(fixture.name)")
            print(polished)
            print("PROMPT_ITERATION_OUTPUT_END")
        }
        print(
            "PROMPT_ITERATION_TOTAL raw_errors=\(totalRaw) polished_errors=\(totalPolished) "
                + "reference_words=\(totalReference) polished_wer=\(String(format: "%.3f", Double(totalPolished) / Double(max(1, totalReference)) * 100))"
        )
    }

    private func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
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
}
