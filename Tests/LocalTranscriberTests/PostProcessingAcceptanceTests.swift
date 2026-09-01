import XCTest
@testable import LocalTranscriber

final class PostProcessingAcceptanceTests: XCTestCase {
    private struct Case {
        let name: String
        let input: String
        let expected: String
    }

    func testAllModelsPolishRepresentativeSpeechMistakes() async throws {
        guard ProcessInfo.processInfo.environment["WORDMATE_RUN_MODEL_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Run explicitly with WORDMATE_RUN_MODEL_ACCEPTANCE=1")
        }

        let processor = TranscriptPostProcessor()
        let environment = ProcessInfo.processInfo.environment
        let requestedModel = environment["WORDMATE_ACCEPTANCE_MODEL"]
        let requestedCase = environment["WORDMATE_ACCEPTANCE_CASE"]
        let models = PostProcessingModel.allCases.filter {
            requestedModel == nil || $0.rawValue == requestedModel || $0.displayName == requestedModel
        }
        let cases = Self.cases.filter {
            requestedCase == nil || $0.name == requestedCase
        }

        XCTAssertFalse(models.isEmpty, "WORDMATE_ACCEPTANCE_MODEL did not match a model")
        XCTAssertFalse(cases.isEmpty, "WORDMATE_ACCEPTANCE_CASE did not match a case")

        for model in models {
            for testCase in cases {
                let output = try await processor.polish(testCase.input, using: model)
                let actual = Self.normalized(output)
                let expected = Self.normalized(testCase.expected)

                print("WORDMATE ACCEPTANCE — \(model.displayName) — \(testCase.name)")
                print(actual)
                XCTAssertEqual(actual, expected, "\(model.displayName) failed \(testCase.name)")
            }
        }
    }

    private static let cases: [Case] = [
        Case(
            name: "accidental repetitions",
            input: "I think I think we should update this function before before merging.",
            expected: "I think we should update this function before merging."
        ),
        Case(
            name: "intentional emphasis",
            input: "The result was very very good, exactly what we wanted.",
            expected: "The result was very very good, exactly what we wanted."
        ),
        Case(
            name: "intentional repeated construction",
            input: "All I say is, kings is kings, and you got to make allowances.",
            expected: "All I say is, kings is kings, and you got to make allowances."
        ),
        Case(
            name: "punctuation",
            input: "The feature is ready it works well should we release it tomorrow",
            expected: "The feature is ready. It works well. Should we release it tomorrow?"
        ),
        Case(
            name: "self correction",
            input: "We should deploy on Thursday, sorry, I mean Friday, after after the tests pass.",
            expected: "We should deploy on Friday after the tests pass."
        ),
    ]

    private static func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "’", with: "'")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
