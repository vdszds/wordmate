import Foundation

enum AudioLevelNormalizer {
    private static let noiseFloorDecibels = -50.0
    private static let maximumDecibels = 0.0
    private static let responseCurve = 1.2

    static func normalize(decibels: Double) -> Double {
        guard decibels.isFinite else { return 0 }

        let linear = (decibels - noiseFloorDecibels)
            / (maximumDecibels - noiseFloorDecibels)
        let clamped = max(0, min(1, linear))
        return pow(clamped, responseCurve)
    }
}
