import XCTest
@testable import LocalTranscriber

final class TranscriptCleanerTests: XCTestCase {
    func testRemovesStandaloneFillersAndTheirSeparatingPunctuation() {
        XCTAssertEqual(
            TranscriptCleaner.clean("Um, I think, uh, this is great."),
            "I think this is great."
        )
    }

    func testRemovesElongatedAndTrailingFillers() {
        XCTAssertEqual(
            TranscriptCleaner.clean("That was useful, uhhh."),
            "That was useful."
        )
    }

    func testDoesNotRemoveFillersInsideWordsOrHyphenatedSpeech() {
        XCTAssertEqual(
            TranscriptCleaner.clean("The umbrella and uh-huh response remain."),
            "The umbrella and uh-huh response remain."
        )
    }

    func testFillerOnlyTranscriptBecomesEmpty() {
        XCTAssertEqual(TranscriptCleaner.clean("Um, uh."), "")
    }
}
