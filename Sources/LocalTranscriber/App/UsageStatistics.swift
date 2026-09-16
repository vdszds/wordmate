import Combine
import Foundation

@MainActor
final class UsageStatistics: ObservableObject {
    private enum Key {
        static let totalWords = "usage.totalWords"
        static let totalRecordingDuration = "usage.totalRecordingDuration"
    }

    @Published private(set) var totalWords: Int
    @Published private(set) var totalRecordingDuration: TimeInterval

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        totalWords = max(0, defaults.integer(forKey: Key.totalWords))
        totalRecordingDuration = max(
            0,
            defaults.double(forKey: Key.totalRecordingDuration)
        )
    }

    func record(transcript: String, duration: TimeInterval) {
        totalWords += Self.wordCount(in: transcript)
        totalRecordingDuration += max(0, duration)

        defaults.set(totalWords, forKey: Key.totalWords)
        defaults.set(
            totalRecordingDuration,
            forKey: Key.totalRecordingDuration
        )
    }

    var formattedRecordingDuration: String {
        let seconds = Int(totalRecordingDuration.rounded())
        guard seconds > 0 else { return "0 min" }
        guard seconds >= 60 else { return "<1 min" }

        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes) min"
    }

    static func wordCount(in transcript: String) -> Int {
        transcript.split { character in
            !character.isLetter
                && !character.isNumber
                && character != "'"
                && character != "’"
        }.count
    }
}
