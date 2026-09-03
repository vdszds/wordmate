import XCTest
@testable import LocalTranscriber

final class ParagraphPlannerTests: XCTestCase {
    private func text(sentences: Int, wordsEach: Int = 16, opener: (Int) -> String = { _ in "The" }) -> String {
        (0..<sentences).map { index in
            ([opener(index)] + Array(repeating: "word", count: wordsEach - 1)).joined(separator: " ") + "."
        }.joined(separator: " ")
    }

    func testShortDictationsStayOneParagraph() {
        XCTAssertEqual(ParagraphPlanner.paragraphStarts(in: text(sentences: 7)), [])
        XCTAssertEqual(ParagraphPlanner.paragraphStarts(in: text(sentences: 12, wordsEach: 6)), [])
    }

    func testLongDictationsBreakAboutEveryThreeSentences() {
        XCTAssertEqual(ParagraphPlanner.paragraphStarts(in: text(sentences: 10)), [3, 6])
        XCTAssertEqual(ParagraphPlanner.paragraphStarts(in: text(sentences: 11)), [3, 6, 9])
    }

    func testBreaksAvoidSentencesThatContinueThePreviousOne() {
        let starts = ParagraphPlanner.paragraphStarts(
            in: text(sentences: 10, opener: { $0 == 3 ? "He" : "The" })
        )
        XCTAssertEqual(starts, [4, 7])
    }

    func testBreaksAreAppliedAsBlankLinesBetweenSentences() {
        let joined = TranscriptPolishPolicy.applyingParagraphBreaks(
            to: "One here. Two here. Three here. Four here.",
            startingAt: [2]
        )
        XCTAssertEqual(joined, "One here. Two here.\n\nThree here. Four here.")
    }
}
