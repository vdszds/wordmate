import AppKit
import Foundation

/// Removes unmistakable partial-word retries from raw ASR text before the
/// language model sees it: "s simply", "typ typesetting", "consec consectetur".
///
/// A fragment is deleted only when it is a strict prefix of the word that
/// follows it and is not itself a word in the user's spelling language, so
/// "the theory" and "in industry" are never touched. Single-letter fragments
/// are handled for English only, where no single letter but "a" and "I" is a
/// word. Everything the dictionary accepts is left for Qwen to judge.
enum PartialWordRetryCleaner {
    private struct Token {
        let normalized: String
        let range: Range<String.Index>
    }

    static func removingRetries(from text: String) -> String {
        let tokens = tokens(in: text)
        guard tokens.count >= 2,
              let language = SpellingDictionary.language else { return text }

        var deleted = Array(repeating: false, count: tokens.count)
        var index = tokens.count - 2
        while index >= 0 {
            // Adjacency is checked against the immediately following token;
            // deleted tokens in between were themselves adjacent retries.
            var next = index + 1
            while next < tokens.count, deleted[next] { next += 1 }
            if next < tokens.count,
               onlySeparators(
                   between: tokens[index].range.upperBound,
                   and: tokens[index + 1].range.lowerBound,
                   in: text
               ),
               isRetry(tokens[index], of: tokens[next], in: text, language: language) {
                deleted[index] = true
            }
            index -= 1
        }
        guard deleted.contains(true) else { return text }

        var result = ""
        var cursor = text.startIndex
        var position = 0
        while position < tokens.count {
            guard deleted[position] else {
                position += 1
                continue
            }
            result += text[cursor..<tokens[position].range.lowerBound]
            var next = position + 1
            while next < tokens.count, deleted[next] { next += 1 }
            // The last token is never deleted, so a retained token follows.
            cursor = tokens[next].range.lowerBound
            position = next
        }
        result += text[cursor...]
        return result
    }

    private static func isRetry(
        _ fragment: Token,
        of completed: Token,
        in text: String,
        language: String
    ) -> Bool {
        guard completed.normalized.count > fragment.normalized.count,
              completed.normalized.count >= 3,
              completed.normalized.hasPrefix(fragment.normalized),
              fragment.normalized.allSatisfy(\.isLetter),
              completed.normalized.allSatisfy(\.isLetter),
              !isAttached(fragment.range, in: text),
              !isAttached(completed.range, in: text)
        else { return false }

        if fragment.normalized.count == 1 {
            guard language.hasPrefix("en") else { return false }
            return fragment.normalized != "a" && fragment.normalized != "i"
        }
        return !SpellingDictionary.isWord(String(text[fragment.range]), language: language)
    }

    private static func isAttached(_ range: Range<String.Index>, in text: String) -> Bool {
        let joiners: Set<Character> = ["'", "’", "-", "‐", "‑", "–", "."]
        if range.lowerBound > text.startIndex,
           joiners.contains(text[text.index(before: range.lowerBound)]) {
            return true
        }
        if range.upperBound < text.endIndex {
            let following = text[range.upperBound]
            if following == "'" || following == "’" || following == "-" {
                return true
            }
        }
        return false
    }

    private static func onlySeparators(
        between start: String.Index,
        and end: String.Index,
        in text: String
    ) -> Bool {
        text[start..<end].allSatisfy { $0.isWhitespace || $0 == "," || $0 == "." }
    }

    private static func tokens(in text: String) -> [Token] {
        var result: [Token] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character.isNumber {
                if start == nil { start = index }
            } else if let wordStart = start {
                result.append(
                    Token(normalized: text[wordStart..<index].lowercased(), range: wordStart..<index)
                )
                start = nil
            }
            index = text.index(after: index)
        }
        if let wordStart = start {
            result.append(
                Token(normalized: text[wordStart...].lowercased(), range: wordStart..<text.endIndex)
            )
        }
        return result
    }
}

/// Thin wrapper over the system spell checker. Every call is made on the main
/// thread, where AppKit expects it, and results are memoized per word.
enum SpellingDictionary {
    private static let lock = NSLock()
    private static var cachedLanguage: String??
    private static var cache: [String: Bool] = [:]

    /// The user's explicit spelling language, or nil when the checker cannot
    /// name one (for example "Multilingual"), in which case no rule applies.
    static var language: String? {
        lock.lock()
        if let cachedLanguage {
            lock.unlock()
            return cachedLanguage
        }
        lock.unlock()

        let resolved: String? = onMain {
            let language = NSSpellChecker.shared.language()
            guard !language.isEmpty,
                  language.lowercased() != "multilingual",
                  language.lowercased() != "automatic" else { return nil }
            return language
        }
        lock.lock()
        cachedLanguage = .some(resolved)
        lock.unlock()
        return resolved
    }

    static func isWord(_ word: String, language: String) -> Bool {
        let key = language + "\u{1F}" + word
        lock.lock()
        if let known = cache[key] {
            lock.unlock()
            return known
        }
        lock.unlock()

        let result: Bool = onMain {
            NSSpellChecker.shared.checkSpelling(
                of: word,
                startingAt: 0,
                language: language,
                wrap: false,
                inSpellDocumentWithTag: 0,
                wordCount: nil
            ).location == NSNotFound
        }
        lock.lock()
        cache[key] = result
        lock.unlock()
        return result
    }

    private static func onMain<T>(_ body: () -> T) -> T {
        if Thread.isMainThread {
            return body()
        }
        return DispatchQueue.main.sync(execute: body)
    }
}
