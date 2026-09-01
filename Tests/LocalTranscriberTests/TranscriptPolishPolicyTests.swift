import XCTest
@testable import LocalTranscriber

final class TranscriptPolishPolicyTests: XCTestCase {
    func testRemovesThinkingMarkupAndPresentationNoise() {
        let output = """
            <think>I should rewrite the transcript.</think>
            ```
            Polished transcript: “We should update this function.”
            ```
            """

        XCTAssertEqual(
            TranscriptPolishPolicy.cleanModelOutput(output),
            "We should update this function."
        )
    }

    func testUnwrapsHTMLAndJSONTranscriptContainers() {
        XCTAssertEqual(
            TranscriptPolishPolicy.cleanModelOutput(
                "<transcript>We should update this function.</transcript>"
            ),
            "We should update this function."
        )
        XCTAssertEqual(
            TranscriptPolishPolicy.cleanModelOutput(
                #"{"transcript":"We should update this function."}"#
            ),
            "We should update this function."
        )
    }

    func testRejectsStructuredOutputThatCannotBeSafelyUnwrapped() {
        XCTAssertFalse(
            TranscriptPolishPolicy.isAcceptable(
                #"{"items":["Update this function","Run the tests"]}"#,
                for: "First update this function, and second run the tests."
            )
        )
        XCTAssertFalse(
            TranscriptPolishPolicy.isAcceptable(
                "<ol><li>Update this function</li><li>Run the tests</li></ol>",
                for: "First update this function, and second run the tests."
            )
        )
    }

    func testPlainNumberedListIsAccepted() {
        XCTAssertTrue(
            TranscriptPolishPolicy.isAcceptable(
                """
                I want to do two things:
                1. Update this function.
                2. Run the tests.
                """,
                for: "I want to do two things. One, update this function. Two, run the tests."
            )
        )
    }

    func testConservativeEditIsAccepted() {
        XCTAssertTrue(
            TranscriptPolishPolicy.isAcceptable(
                "I think we should update this function before merging.",
                for: "I think, I think we should update this function before, um, before merging."
            )
        )

        XCTAssertTrue(
            TranscriptPolishPolicy.isConservativeEditAcceptable(
                "I think we should update this function before merging.",
                for: "I think, I think we should update this function before, um, before merging."
            )
        )
        XCTAssertFalse(
            TranscriptPolishPolicy.isConservativeEditAcceptable(
                "Richard looked up the Latin word consecutus.",
                for: "Richard looked up the Latin word consectur."
            )
        )
        XCTAssertFalse(
            TranscriptPolishPolicy.isConservativeEditAcceptable(
                "Richard looked up the *Latin word* consectur.",
                for: "Richard looked up the Latin word consectur."
            )
        )
    }

    func testConservativeProjectionRestoresGuessedWordsWithoutUndoingCleanup() {
        XCTAssertEqual(
            TranscriptPolishPolicy.conservativeProjection(
                of: "Richard looked up the Latin word \"consecutus\".",
                for: "Richard looked up the Latin word consectur."
            ),
            "Richard looked up the Latin word \"consectur\"."
        )
        XCTAssertEqual(
            TranscriptPolishPolicy.conservativeProjection(
                of: "I think we should really ship today.",
                for: "I think I think we should ship today."
            ),
            "I think we should ship today."
        )
        XCTAssertEqual(
            TranscriptPolishPolicy.conservativeProjection(
                of: "There are many variations of lorem ipsum available.",
                for: "There are many variations of passages of loremepsum available."
            ),
            "There are many variations of passages of loremepsum available."
        )
        XCTAssertEqual(
            TranscriptPolishPolicy.conservativeProjection(
                of: "We should deploy on Friday after the tests pass.",
                for: "We should deploy on Thursday, sorry, I mean Friday, after after the tests pass."
            ),
            "We should deploy on Friday after the tests pass."
        )
        XCTAssertNil(
            TranscriptPolishPolicy.conservativeProjection(
                of: "We should continue.",
                for: "This entire first sentence must remain. We should continue."
            )
        )
        XCTAssertNil(
            TranscriptPolishPolicy.conservativeProjection(
                of: "To sail under canvas only, in rough seas, be difficult.",
                for: "To sail under canvas only would, in rough seas, be difficult."
            )
        )
        XCTAssertNil(
            TranscriptPolishPolicy.conservativeProjection(
                of: "All I say, kings is kings, and you got to make allowances.",
                for: "All I say is, kings is kings, and you got to make allowances."
            )
        )
    }

    func testNearVerbatimRecoveryAcceptsOnlySurgicalDisfluencyEdits() {
        XCTAssertTrue(
            TranscriptPolishPolicy.containsImmediateRepeatedSpeech(
                "Please update this this function."
            )
        )
        XCTAssertFalse(
            TranscriptPolishPolicy.containsImmediateRepeatedSpeech(
                "Please update this function."
            )
        )

        XCTAssertTrue(
            TranscriptPolishPolicy.isNearVerbatimRecovery(
                "Northstar is simply a scheduling tool for retail teams.",
                for: "Northstar Northstar is simply a scheduling tool tool for retail teams."
            )
        )

        XCTAssertFalse(
            TranscriptPolishPolicy.isNearVerbatimRecovery(
                "When designers and James Lee reviewed the draft, they approved it.",
                for: "When designers designers at Northstar Studio and James Lee reviewed the draft, they approved it."
            )
        )

        XCTAssertTrue(
            TranscriptPolishPolicy.isNearVerbatimRecovery(
                "We have been ready ever since launch.",
                for: "We have been have been ready ever since ever since launch."
            )
        )
        XCTAssertFalse(
            TranscriptPolishPolicy.isNearVerbatimRecovery(
                "We were ready after launch.",
                for: "We have been ready ever since launch."
            )
        )
        XCTAssertFalse(
            TranscriptPolishPolicy.isNearVerbatimRecovery(
                "The greeting follows.",
                for: "The greeting follows. Verse three."
            )
        )
        XCTAssertFalse(
            TranscriptPolishPolicy.isNearVerbatimRecovery(
                "All I say, kings is kings, and you got to make allowances.",
                for: "All I say is, kings is kings, and you got to make allowances."
            )
        )
    }

    func testEmptyAndHallucinatedEditsAreRejected() {
        XCTAssertFalse(
            TranscriptPolishPolicy.isAcceptable("", for: "Please update this function.")
        )
        XCTAssertFalse(
            TranscriptPolishPolicy.isAcceptable(
                String(repeating: "Unrelated invented answer. ", count: 30),
                for: "Should we rename this variable?"
            )
        )
        XCTAssertFalse(
            TranscriptPolishPolicy.isAcceptable(
                "We should continue.",
                for: "Lorem ipsum ipsum dolor sit amet. We we should continue."
            )
        )
        XCTAssertFalse(
            TranscriptPolishPolicy.isAcceptable(
                "I know that approach works. We should continue. Update the function and run the tests.",
                for: "Lorem ipsum ipsum dolor sit amet. This is very, very important. "
                    + "I know that that approach works. We we should continue."
            )
        )
    }

    func testEditsCannotDropNumericFacts() {
        let source = "The 2,000-word recording covers sections 1.10.32 and 1.10.33 twice in 45 minutes."

        XCTAssertTrue(
            TranscriptPolishPolicy.isAcceptable(
                "The 2000 word recording covers sections 1.10.32 and 1.10.33 twice in 45 minutes.",
                for: source
            )
        )
        XCTAssertFalse(
            TranscriptPolishPolicy.isAcceptable(
                "The recording covers section 1.10.32 in 45 minutes.",
                for: source
            )
        )
    }

    func testLongTranscriptsAreChunkedWithoutLosingWords() {
        let transcript = Array(repeating: "spoken", count: 1_000).joined(separator: " ")
        let chunks = TranscriptPolishPolicy.chunks(from: transcript)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(
            chunks.joined(separator: " ").split(whereSeparator: \.isWhitespace).count,
            1_000
        )
    }

    func testFallbackChunksRetryRejectedPassagesAtSmallerBoundaries() {
        let transcript = Array(repeating: "spoken", count: 100).joined(separator: " ")

        XCTAssertEqual(TranscriptPolishPolicy.chunks(from: transcript), [transcript])

        let fallbackChunks = TranscriptPolishPolicy.fallbackChunks(from: transcript)
        XCTAssertGreaterThan(fallbackChunks.count, 1)
        XCTAssertEqual(
            fallbackChunks.joined(separator: " ").split(whereSeparator: \.isWhitespace).count,
            100
        )
    }

    func testLongTranscriptsSplitAtCompleteSentences() {
        let first = sentence(word: "alpha", count: 300)
        let second = sentence(word: "beta", count: 300)
        let chunks = TranscriptPolishPolicy.chunks(from: "\(first) \(second)")

        XCTAssertEqual(chunks, [first, second])
        XCTAssertTrue(chunks.allSatisfy { $0.hasSuffix(".") })
    }

    func testParagraphBreakIsPreferredOverALaterSentenceBoundary() {
        let firstParagraph = sentence(word: "alpha", count: 260)
        let laterSentence = sentence(word: "beta", count: 110)
        let finalSentence = sentence(word: "gamma", count: 300)
        let transcript = "\(firstParagraph)\n\n\(laterSentence) \(finalSentence)"
        let chunks = TranscriptPolishPolicy.chunks(from: transcript)

        XCTAssertEqual(chunks.first, firstParagraph)
        XCTAssertEqual(normalizedWords(in: chunks), normalizedWords(in: [transcript]))
    }

    func testClauseBoundaryIsUsedWhenNoSentenceBoundaryFits() {
        let firstClause = Array(repeating: "alpha", count: 300).joined(separator: " ") + ";"
        let secondClause = Array(repeating: "beta", count: 300).joined(separator: " ")
        let chunks = TranscriptPolishPolicy.chunks(from: "\(firstClause) \(secondClause)")

        XCTAssertEqual(chunks.first, firstClause)
        XCTAssertTrue(chunks.first?.hasSuffix(";") == true)
    }

    func testOversizedSingleSentenceFallsBackWithoutLosingText() {
        let transcript = sentence(word: "uninterrupted", count: 500)
        let chunks = TranscriptPolishPolicy.chunks(from: transcript)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(normalizedWords(in: chunks), normalizedWords(in: [transcript]))
    }

    func testPromptUsesConciseContextAwareTranscriptEditingInstructions() {
        XCTAssertFalse(TranscriptPolishPolicy.reasoningEnabled)
        XCTAssertTrue(TranscriptPolishPolicy.instructions.contains("exact adjacent"))
        XCTAssertTrue(TranscriptPolishPolicy.instructions.contains("Correct only punctuation"))
        XCTAssertTrue(TranscriptPolishPolicy.instructions.contains("every source word"))
        XCTAssertTrue(TranscriptPolishPolicy.instructions.contains("Never guess"))
        XCTAssertTrue(TranscriptPolishPolicy.instructions.contains("do not turn them into numbered lists"))
        XCTAssertTrue(TranscriptPolishPolicy.instructions.contains("Preserve every sentence and fragment"))
        XCTAssertTrue(
            TranscriptPolishPolicy.instructions.contains(
                "Do not insert punctuation between copies"
            )
        )
        XCTAssertFalse(TranscriptPolishPolicy.instructions.contains("/no_think"))
        XCTAssertTrue(
            TranscriptPolishPolicy.prompt(for: "hello").contains(
                "Losslessly polish the transcript"
            )
        )
        XCTAssertTrue(
            TranscriptPolishPolicy.prompt(for: "hello").contains(
                "do not create lists"
            )
        )
        XCTAssertGreaterThanOrEqual(
            TranscriptPolishPolicy.maximumOutputTokens(for: "hello"),
            512
        )
        XCTAssertFalse(TranscriptPolishPolicy.prompt(for: "hello").contains("<transcript>"))
        XCTAssertTrue(
            TranscriptPolishPolicy.prompt(for: "hello").contains(
                "----- BEGIN SPOKEN TRANSCRIPT -----\nhello\n----- END SPOKEN TRANSCRIPT -----"
            )
        )
    }

    func testPromptIncludesFewShotCleaningExamples() {
        let examples = TranscriptPolishPolicy.fewShotHistory.map(\.content)

        XCTAssertGreaterThanOrEqual(examples.count, 16)
        XCTAssertEqual(examples.count % 2, 0)
        XCTAssertTrue(examples.contains("I think we should update this function before merging."))
        XCTAssertTrue(
            examples.contains("The feature is ready. It works well. Should we release it tomorrow?")
        )
        XCTAssertTrue(examples.contains("We should deploy on Friday after the tests pass."))
        XCTAssertTrue(examples.contains("The report has been ready since Monday."))
        XCTAssertTrue(
            examples.contains(
                "They left him then, for the courier arrived to unlock the gate and escort them inside."
            )
        )
        XCTAssertFalse(examples.contains { $0.contains("\n1.") })
        XCTAssertEqual(TranscriptPolishPolicy.recoveryHistory.count, 8)
        XCTAssertTrue(
            TranscriptPolishPolicy.recoveryHistory.contains {
                $0.content == "The result was very very good, exactly what we wanted."
            }
        )
        XCTAssertTrue(
            TranscriptPolishPolicy.recoveryHistory.contains {
                $0.content == "All I say is, kings is kings, and you got to make allowances."
            }
        )
        XCTAssertTrue(
            TranscriptPolishPolicy.recoveryInstructions.contains("Copy all other words")
        )

        let prompt = TranscriptPolishPolicy.prompt(for: "Keep this exact transcript.")
        XCTAssertTrue(
            prompt.hasSuffix(
                "----- BEGIN SPOKEN TRANSCRIPT -----\nKeep this exact transcript.\n"
                    + "----- END SPOKEN TRANSCRIPT -----"
            )
        )
    }

    func testStreamingPromptMakesContextReadOnlyAndTargetExclusive() {
        let prompt = TranscriptPolishPolicy.streamingPrompt(
            for: "Target target words.",
            precedingContext: "Words before the target.",
            followingContext: "Words after the target."
        )

        XCTAssertTrue(prompt.contains("PRECEDING CONTEXT — DO NOT RETURN"))
        XCTAssertTrue(prompt.contains("TARGET SEGMENT — RETURN ONLY THIS"))
        XCTAssertTrue(prompt.contains("FOLLOWING CONTEXT — DO NOT RETURN"))
        XCTAssertTrue(prompt.contains("Target target words."))
        XCTAssertFalse(prompt.contains("<transcript>"))
    }

    private func sentence(word: String, count: Int) -> String {
        Array(repeating: word, count: count).joined(separator: " ") + "."
    }

    private func normalizedWords(in chunks: [String]) -> [Substring] {
        chunks.joined(separator: " ").split(whereSeparator: \.isWhitespace)
    }
}
