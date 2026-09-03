import Foundation

enum TranscriptCleaner {
    static func clean(_ transcript: String) -> String {
        var text = transcript
        let filler = #"(?<![\p{L}\p{N}'’\-])(?:um+|uh+)(?![\p{L}\p{N}'’\-])"#

        // Remove fillers together with punctuation that only existed to set them apart.
        text = replacing(#"\(\s*"# + filler + #"\s*\)"#, in: text, with: " ")
        text = replacing(#"\s*[,;:]\s*"# + filler + #"\s*[,;:]\s*"#, in: text, with: " ")
        text = replacing(#"^\s*"# + filler + #"\s*[,;:]?\s*"#, in: text, with: "")
        text = replacing(#"([.!?])\s*"# + filler + #"\s*[,;:]?\s*"#, in: text, with: "$1 ")
        text = replacing(#"\s*[,;:]\s*"# + filler + #"(?=\s*(?:[.!?]|$))"#, in: text, with: "")
        text = replacing(filler, in: text, with: " ")

        // Hedging "like" and parenthetical "you know" are identifiable from
        // their neighbours; small models leave most of them in otherwise.
        text = DiscourseFillerCleaner.removingFillers(from: text)

        // Drop unmistakable partial-word retries such as "s simply" so a
        // stray letter or word fragment never reaches the pasted text.
        text = PartialWordRetryCleaner.removingRetries(from: text)

        // Repair whitespace and punctuation left behind by the removed words.
        text = replacing(#"\s+"#, in: text, with: " ")
        text = replacing(#"\s+([,.;:!?])"#, in: text, with: "$1")
        text = replacing(#"([,;:])(?:\s*[,;:])+"#, in: text, with: "$1")
        text = replacing(#"[,;:]\s*([.!?])"#, in: text, with: "$1")
        text = replacing(#"([.!?])\s*[,;:]\s*"#, in: text, with: "$1 ")
        text = replacing(#"^\s*[,;:]\s*"#, in: text, with: "")

        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.rangeOfCharacter(from: .alphanumerics) != nil else {
            return ""
        }
        return cleaned
    }

    private static func replacing(
        _ pattern: String,
        in text: String,
        with replacement: String
    ) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return text
        }

        return expression.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: replacement
        )
    }
}
