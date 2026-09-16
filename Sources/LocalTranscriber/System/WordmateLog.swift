import Foundation
import os

/// Structured, privacy-safe logging. Transcript text is never logged.
///
/// Read on any Mac with:
/// `log show --last 1h --predicate 'subsystem == "sh.wordmate.app"' --info --style compact`
enum WordmateLog {
    static let subsystem = "sh.wordmate.app"
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let dictation = Logger(subsystem: subsystem, category: "dictation")
}
