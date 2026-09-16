import XCTest
@testable import LocalTranscriber

final class LiveAudioWaveformTests: XCTestCase {
    func testWaveformWarmupStaysQuietAndTravels() {
        let count = LiveAudioWaveform.barProfile.count
        for phase in stride(from: 0.0, through: 1.0, by: 0.1) {
            for index in 0..<count {
                let response = LiveAudioWaveform.warmupResponse(
                    at: index,
                    phase: phase,
                    animated: true
                )
                XCTAssertGreaterThan(response, 0.05)
                XCTAssertLessThan(
                    response,
                    0.45,
                    "Warm-up must stay well below a speaking level"
                )
            }
        }

        func peakIndex(phase: Double) -> Int {
            (0..<count).max { lhs, rhs in
                LiveAudioWaveform.warmupResponse(at: lhs, phase: phase, animated: true)
                    < LiveAudioWaveform.warmupResponse(at: rhs, phase: phase, animated: true)
            }!
        }

        XCTAssertLessThan(peakIndex(phase: 0.15), peakIndex(phase: 0.5))
        XCTAssertLessThan(peakIndex(phase: 0.5), peakIndex(phase: 0.85))

        let still = (0..<count).map {
            LiveAudioWaveform.warmupResponse(at: $0, phase: 0.3, animated: false)
        }
        XCTAssertEqual(still.max(), still[count / 2])
        XCTAssertLessThan(still.max()!, 0.2)
    }
}
