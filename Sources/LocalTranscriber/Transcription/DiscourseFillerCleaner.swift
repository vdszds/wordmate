import Foundation

/// Removes the two spoken fillers that small language models most often leave
/// behind and that can be identified from their neighbours alone: hedging
/// "like" ("he's now like not responsive", "like I told him") and the
/// parenthetical "you know". Comparisons ("like a person", "like AWS"), the
/// verb ("I like"), idioms ("like I said") and "you know the answer" stay.
/// Measured against a human-edited reference the rules agree with the editor
/// in roughly four of five cases, which the models were far from reaching.
enum DiscourseFillerCleaner {
    static func removingFillers(from text: String) -> String {
        var result = removingHedgingLike(from: text)
        result = removingParentheticalYouKnow(from: result)
        return result
    }

    private static let likeExpression: NSRegularExpression? = {
        let precedingWords = [
            "so", "and", "but", "because", "is", "was", "are", "were", "now", "just", "it's", "that's",
            "there's", "then", "yeah", "he's", "she's", "they're", "we're", "i'm", "you're", "of",
            "really", "also", "or", "there", "basically", "actually",
        ]
        .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: "'", with: "['’]") }
        .joined(separator: "|")
        let pattern = "(?i)(?:(?<=^)|(?<=[.?!,;:]\\s)|(?<=[.?!,;:])|(?<=\\b(?:" + precedingWords + ")\\s))"
            + "like(?=\\s|[,.;:!?]|$)"
            + "(?!\\s*[,;:]?\\s*(?:a|an|the|this|that|these|those|i\\s+said)\\b)"
            + "(?!\\s*[,;:]?\\s*(?-i:[A-Z][A-Za-z]))"
        return try? NSRegularExpression(pattern: pattern)
    }()

    private static let youKnowExpression: NSRegularExpression? = {
        let pattern = "(?i)(?<!\\b(?:do|did|does|don['’]t|doesn['’]t|didn['’]t|as|if|than|well|let)\\s)"
            + "you\\s+know(?=\\s|[,.;:!?]|$)"
            + "(?!\\s*[,;:]?\\s*(?:the|that|what|how|if|who|whom|this|a|an|it|him|her|them|about|of|which|where|why|when|my|your|our|their|his|its|these|those|there|me|us|better|best|already|exactly)\\b)"
        return try? NSRegularExpression(pattern: pattern)
    }()

    private static func removingHedgingLike(from text: String) -> String {
        removing(likeExpression, from: text)
    }

    private static func removingParentheticalYouKnow(from text: String) -> String {
        removing(youKnowExpression, from: text)
    }

    private static func removing(_ expression: NSRegularExpression?, from text: String) -> String {
        guard let expression else { return text }
        let nsText = text as NSString
        let matches = expression.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            guard var range = Range(match.range, in: result) else { continue }
            // Swallow one of the commas around a parenthetical filler so
            // "told him, like, ten times" becomes "told him, ten times".
            var after = range.upperBound
            while after < result.endIndex, result[after].isWhitespace {
                after = result.index(after: after)
            }
            var before = range.lowerBound
            while before > result.startIndex, result[result.index(before: before)].isWhitespace {
                before = result.index(before: before)
            }
            let precededByComma = before > result.startIndex && result[result.index(before: before)] == ","
            if after < result.endIndex, result[after] == ",", precededByComma {
                range = range.lowerBound..<result.index(after: after)
                after = result.index(after: after)
            }
            let startsSentence = before == result.startIndex
                || StreamingTranscriptPolicy.isStrongTerminator(result[result.index(before: before)])
            result.removeSubrange(range)
            if startsSentence {
                // "Like I call him" became "I call him": restore the capital.
                var cursor = range.lowerBound
                while cursor < result.endIndex, !result[cursor].isLetter, !result[cursor].isNumber {
                    if StreamingTranscriptPolicy.isStrongTerminator(result[cursor]) { break }
                    cursor = result.index(after: cursor)
                }
                if cursor < result.endIndex, result[cursor].isLowercase {
                    result.replaceSubrange(cursor...cursor, with: String(result[cursor]).uppercased())
                }
            }
        }
        return result
    }
}
