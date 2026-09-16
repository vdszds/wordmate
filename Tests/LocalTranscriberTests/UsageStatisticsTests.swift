import XCTest
@testable import LocalTranscriber

@MainActor
final class UsageStatisticsTests: XCTestCase {
    func testCompletedTranscriptionsAccumulateAndPersist() {
        let suiteName = "UsageStatisticsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let statistics = UsageStatistics(defaults: defaults)
        statistics.record(
            transcript: "Hello, don't stop—this is Wordmate 2.",
            duration: 3_725
        )

        XCTAssertEqual(statistics.totalWords, 7)
        XCTAssertEqual(statistics.totalRecordingDuration, 3_725)
        XCTAssertEqual(statistics.formattedRecordingDuration, "1h 2m")

        let restored = UsageStatistics(defaults: defaults)
        XCTAssertEqual(restored.totalWords, 7)
        XCTAssertEqual(restored.totalRecordingDuration, 3_725)
    }

    func testDurationFormattingHandlesNewAndShortUsage() {
        let suiteName = "UsageStatisticsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let statistics = UsageStatistics(defaults: defaults)
        XCTAssertEqual(statistics.formattedRecordingDuration, "0 min")

        statistics.record(transcript: "A short test", duration: 24)
        XCTAssertEqual(statistics.formattedRecordingDuration, "<1 min")
    }
}
