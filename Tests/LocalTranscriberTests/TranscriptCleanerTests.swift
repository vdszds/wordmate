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

    func testPartialWordRetriesAreRemovedButDictionaryWordsStay() throws {
        guard let language = SpellingDictionary.language, language.hasPrefix("en") else {
            throw XCTSkip("Requires an English spelling language")
        }

        XCTAssertEqual(
            TranscriptCleaner.clean(
                "Lorem Ipsum is s simply dummy text of the typ typesetting industry."
            ),
            "Lorem Ipsum is simply dummy text of the typesetting industry."
        )
        XCTAssertEqual(
            TranscriptCleaner.clean("He looked up the word consec consectetur, and left."),
            "He looked up the word consectetur, and left."
        )
        // Chains of fragments collapse onto the completed word; "Ty" is a
        // dictionary name and therefore stays for the model to judge.
        XCTAssertEqual(
            TranscriptCleaner.clean("Typ typese typesetting is fun."),
            "typesetting is fun."
        )
        XCTAssertEqual(
            TranscriptCleaner.clean("Ty typ typesetting is fun."),
            "Ty typesetting is fun."
        )
        // Real words that prefix the next word are never fragments.
        XCTAssertEqual(
            TranscriptCleaner.clean("This is a treatise on the theory of ethics in industry."),
            "This is a treatise on the theory of ethics in industry."
        )
        XCTAssertEqual(
            TranscriptCleaner.clean("I think a about it. We went to today's meeting."),
            "I think a about it. We went to today's meeting."
        )
        // Attached tokens are not fragments.
        XCTAssertEqual(
            TranscriptCleaner.clean("The industry's standard re-read the co-op's notes."),
            "The industry's standard re-read the co-op's notes."
        )
    }

    func testHedgingLikeAndParentheticalYouKnowAreRemoved() {
        XCTAssertEqual(
            TranscriptCleaner.clean("He's now like not super responsive."),
            "He's now not super responsive."
        )
        XCTAssertEqual(
            TranscriptCleaner.clean("Like I call him and ask him, like what do we need to fill in?"),
            "I call him and ask him, what do we need to fill in?"
        )
        XCTAssertEqual(
            TranscriptCleaner.clean("I told him, like, ten times that we will be away."),
            "I told him, ten times that we will be away."
        )
        XCTAssertEqual(
            TranscriptCleaner.clean("and you know we don't have insurance, right?"),
            "and we don't have insurance, right?"
        )
    }

    func testComparisonsVerbsAndIdiomsKeepLikeAndYouKnow() {
        let untouched = [
            "It looks like a person, and I like that approach.",
            "Something like that is fine, and like I said, it works.",
            "Providers like AWS or Azure offer every service.",
            "Do you know the answer? You know what I mean.",
            "It was like this before, so treat it like the others.",
        ]
        for text in untouched {
            XCTAssertEqual(TranscriptCleaner.clean(text), text)
        }
    }
}
