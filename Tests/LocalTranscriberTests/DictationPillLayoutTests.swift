import XCTest
@testable import LocalTranscriber

final class DictationPillLayoutTests: XCTestCase {
    func testIdleTabProtrudesFivePointsFromScreenEdge() {
        let renderedWidth = DictationPillView.contentSize.width
            * DictationPillView.widthScale(for: .idle)

        XCTAssertEqual(renderedWidth, 5, accuracy: 0.001)
    }

    func testIdleTabIsHalfThePushToTalkLength() {
        let idleHeight = DictationPillView.contentSize.height
            * DictationPillView.heightScale(for: .idle)
        let pushToTalkHeight = DictationPillView.contentSize.height
            * DictationPillView.heightScale(for: .recording(.pushToTalk))

        XCTAssertEqual(idleHeight, pushToTalkHeight / 2, accuracy: 0.001)
    }

    func testIdleTabContainsNoActiveNotchContent() {
        XCTAssertFalse(DictationPillView.hasActiveNotchContent(.idle))
        XCTAssertFalse(
            DictationPillView.hasActiveNotchContent(
                .recording(.gesturePending)
            )
        )
        XCTAssertTrue(
            DictationPillView.hasActiveNotchContent(
                .recording(.pushToTalk)
            )
        )
        XCTAssertTrue(
            DictationPillView.hasActiveNotchContent(
                .recording(.continuous)
            )
        )
    }

    func testIdleCornersAreFlatterThanActiveNotchCorners() {
        let idleScale = DictationPillView.cornerScale(
            forWidthScale: DictationPillView.widthScale(for: .idle)
        )
        let activeScale = DictationPillView.cornerScale(
            forWidthScale: DictationPillView.widthScale(
                for: .recording(.pushToTalk)
            )
        )

        XCTAssertEqual(idleScale, 0.24, accuracy: 0.001)
        XCTAssertEqual(activeScale, 1, accuracy: 0.001)
        XCTAssertLessThan(idleScale, activeScale)
    }
}
