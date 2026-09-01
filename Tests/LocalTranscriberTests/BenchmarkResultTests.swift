import XCTest
@testable import LocalTranscriber

final class BenchmarkResultTests: XCTestCase {
    func testParakeetIsTheOnlySupportedEngine() {
        XCTAssertEqual(EngineChoice.allCases, [.parakeet])
    }

    func testEveryEngineHasUserFacingCopy() {
        for engine in EngineChoice.allCases {
            XCTAssertFalse(engine.displayName.isEmpty)
            XCTAssertFalse(engine.detail.isEmpty)
        }
    }

    func testAudioLevelCurveSuppressesBackgroundNoise() {
        XCTAssertEqual(AudioLevelNormalizer.normalize(decibels: -80), 0)
        XCTAssertLessThan(AudioLevelNormalizer.normalize(decibels: -40), 0.16)
        XCTAssertLessThan(AudioLevelNormalizer.normalize(decibels: -30), 0.35)
    }

    func testAudioLevelCurvePreservesVisibleSpeechRange() {
        let quietSpeech = AudioLevelNormalizer.normalize(decibels: -20)
        let normalSpeech = AudioLevelNormalizer.normalize(decibels: -10)
        let loudSpeech = AudioLevelNormalizer.normalize(decibels: -5)

        XCTAssertGreaterThan(normalSpeech, quietSpeech + 0.20)
        XCTAssertGreaterThan(loudSpeech, normalSpeech + 0.10)
        XCTAssertEqual(AudioLevelNormalizer.normalize(decibels: 3), 1)
    }

    func testModelProgressIsClampedToValidRange() {
        XCTAssertEqual(
            ModelPreparationUpdate(fractionCompleted: -1, status: "Test").fractionCompleted,
            0
        )
        XCTAssertEqual(
            ModelPreparationUpdate(fractionCompleted: 2, status: "Test").fractionCompleted,
            1
        )
    }
}
