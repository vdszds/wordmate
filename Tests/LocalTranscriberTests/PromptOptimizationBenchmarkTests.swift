import Foundation
import XCTest
@testable import LocalTranscriber

final class PromptOptimizationBenchmarkTests: XCTestCase {
    func testHeavyStutterProductionPolicy() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WORDMATE_RUN_PROMPT_OPTIMIZATION"] == "1" else {
            throw XCTSkip("Run explicitly with WORDMATE_RUN_PROMPT_OPTIMIZATION=1")
        }

        let processor = TranscriptPostProcessor()
        let clock = ContinuousClock()
        let started = clock.now
        let output = try await processor.polish(rawTranscript, using: .qwen3_0_6b)
        let elapsed = started.duration(to: clock.now)
        let errorRate = wordErrorRate(output, reference)

        print("PROMPT_POST_PROCESS_SECONDS=\(format(seconds(elapsed)))")
        print("PROMPT_WER_PERCENT=\(format(errorRate * 100))")
        print("PROMPT_OUTPUT_BEGIN")
        print(output)
        print("PROMPT_OUTPUT_END")

        XCTAssertFalse(output.isEmpty)
        XCTAssertLessThan(errorRate, 0.18, "Heavy-stutter WER regressed above the accepted policy")
    }

    private let rawTranscript = """
        Lorem Ipsum Ipsum is simply dummy text text of the printing and typesetting industry. Lorem Ipsum has been has been the industry standard dummy text ever since ever since nineteen sixty six when designers designers at Letra set and James Mosley, the librarian at St. Bridge Brid St Bride Printing Library in London took took a 1914 Cicero translation translation and scrambled it to make dummy text dummy text for Letra sets body type sheets. It has survived survived not only many decades but also the leap into electronic typesetting.
        """

    private let reference = """
        Lorem Ipsum is simply dummy text of the printing and typesetting industry. Lorem Ipsum has been the industry's standard dummy text ever since 1966, when designers at Letraset and James Mosley, the librarian at St Bride Printing Library in London, took a 1914 Cicero translation and scrambled it to make dummy text for Letraset's Body Type sheets. It has survived not only many decades, but also the leap into electronic typesetting.
        """

    private func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func wordErrorRate(_ actual: String, _ expected: String) -> Double {
        let actualWords = normalizedWords(actual)
        let expectedWords = normalizedWords(expected)
        guard !expectedWords.isEmpty else { return actualWords.isEmpty ? 0 : 1 }
        return Double(editDistance(actualWords, expectedWords)) / Double(expectedWords.count)
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
