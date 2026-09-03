import Foundation

/// Rewrites spelled-out English numbers in edited dictation into the numerals
/// a person would type: "twenty four hours" becomes "24 hours", "the twenty
/// eighth" becomes "the 28th", "nineteen sixty six" becomes "1966", "zero
/// percent" becomes "0%", "one point five" becomes "1.5" and digit-by-digit
/// codes such as "zero four three" become "043". Small cardinals and ordinals
/// stay as words except in dates, percentages and decimals, matching common
/// writing style. The rewrite is deterministic and runs after the lossless
/// guard, so the language model never has to invent digits.
enum SpokenNumberFormatter {
    static func format(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var items = tokenize(text)
        var index = 0
        while index < items.count {
            guard let span = numberSpan(in: items, from: index) else {
                index += 1
                continue
            }
            let replacement = span.rendering
            let last = items[span.end - 1]
            var first = items[span.start]
            first.core = replacement
            first.trailing = last.trailing
            first.whitespaceAfter = last.whitespaceAfter
            items.replaceSubrange(span.start..<span.end, with: [first])
            index = span.start + 1
        }
        return items.map { $0.leading + $0.core + $0.trailing + $0.whitespaceAfter }.joined()
    }

    // MARK: - Tokens

    struct Item {
        var leading: String
        var core: String
        var trailing: String
        var whitespaceAfter: String
        var lowercased: String { core.lowercased() }
    }

    static func tokenize(_ text: String) -> [Item] {
        var items: [Item] = []
        var word = ""
        var whitespace = ""
        func flush() {
            guard !word.isEmpty || !whitespace.isEmpty else { return }
            if word.isEmpty {
                if items.isEmpty {
                    items.append(Item(leading: "", core: "", trailing: "", whitespaceAfter: whitespace))
                } else {
                    items[items.count - 1].whitespaceAfter += whitespace
                }
            } else {
                items.append(contentsOf: split(word: word, whitespaceAfter: whitespace))
            }
            word = ""
            whitespace = ""
        }
        for character in text {
            if character.isWhitespace {
                if !word.isEmpty, !whitespace.isEmpty {
                    flush()
                }
                whitespace.append(character)
            } else {
                if !whitespace.isEmpty {
                    flush()
                }
                word.append(character)
            }
        }
        flush()
        return items
    }

    /// Splits a whitespace-delimited word into leading punctuation, core and
    /// trailing punctuation, and breaks "twenty-four" into two number items.
    private static func split(word: String, whitespaceAfter: String) -> [Item] {
        let characters = Array(word)
        var start = 0
        while start < characters.count, !characters[start].isLetter, !characters[start].isNumber {
            start += 1
        }
        var end = characters.count
        while end > start, !characters[end - 1].isLetter, !characters[end - 1].isNumber, characters[end - 1] != "%" {
            end -= 1
        }
        let leading = String(characters[..<start])
        let core = String(characters[start..<end])
        let trailing = String(characters[end...])
        let parts = core.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        if parts.count > 1, parts.allSatisfy({ isNumberWord($0.lowercased()) }) {
            var items: [Item] = []
            for (offset, part) in parts.enumerated() {
                items.append(
                    Item(
                        leading: offset == 0 ? leading : "",
                        core: part,
                        trailing: offset == parts.count - 1 ? trailing : "",
                        whitespaceAfter: offset == parts.count - 1 ? whitespaceAfter : " "
                    )
                )
            }
            return items
        }
        return [Item(leading: leading, core: core, trailing: trailing, whitespaceAfter: whitespaceAfter)]
    }

    // MARK: - Vocabulary

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9,
    ]
    private static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
        "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Int] = [
        "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000,
    ]
    private static let ordinalUnits: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7,
        "eighth": 8, "ninth": 9,
    ]
    private static let ordinalTeens: [String: Int] = [
        "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
    ]
    private static let ordinalTens: [String: Int] = [
        "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50, "sixtieth": 60,
        "seventieth": 70, "eightieth": 80, "ninetieth": 90,
    ]
    private static let months: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september",
        "october", "november", "december",
    ]

    private static func isNumberWord(_ word: String) -> Bool {
        units[word] != nil || teens[word] != nil || tens[word] != nil || scales[word] != nil
            || word == "hundred" || ordinalUnits[word] != nil || ordinalTeens[word] != nil
            || ordinalTens[word] != nil
    }

    // MARK: - Parsing

    struct Span {
        let start: Int
        let end: Int
        let rendering: String
    }

    private enum Kind {
        case cardinal(Int)
        case year(Int)
        case ordinal(Int)
        case digits(String)
        case decimal(String)
    }

    /// Finds the longest number expression starting at `start`, or nil.
    static func numberSpan(in items: [Item], from start: Int) -> Span? {
        guard start < items.count else { return nil }
        let words = items.map(\.lowercased)

        // Digit-by-digit codes: three or more single digits in a row.
        var digitEnd = start
        while digitEnd < items.count, units[words[digitEnd]] != nil,
              digitEnd == start || items[digitEnd - 1].trailing.isEmpty {
            digitEnd += 1
        }
        if digitEnd - start >= 3 {
            let digits = words[start..<digitEnd].map { String(units[$0]!) }.joined()
            return Span(start: start, end: digitEnd, rendering: digits)
        }

        guard let (value, end, spelledSmall) = parseCardinal(words, items: items, from: start) else {
            return parseOrdinalOnly(words, items: items, from: start)
        }

        var kind: Kind = .cardinal(value)
        var spanEnd = end

        // Decimals: "one point five", "one point zero five", "one point ten
        // point thirty two". A fraction is spoken digit by digit or as one
        // small group; a scale word after it ("one point seven billion")
        // stays a word, it is not part of the fraction.
        if spanEnd < words.count, words[spanEnd] == "point", items[spanEnd - 1].trailing.isEmpty {
            var rendering = String(value)
            var cursor = spanEnd
            var consumed = false
            while cursor < words.count, words[cursor] == "point", items[cursor - 1].trailing.isEmpty,
                  items[cursor].trailing.isEmpty {
                guard let (fraction, fractionEnd) = parseFractionDigits(words, items: items, from: cursor + 1) else {
                    break
                }
                rendering += "." + fraction
                cursor = fractionEnd
                consumed = true
            }
            if consumed {
                kind = .decimal(rendering)
                spanEnd = cursor
            }
        }

        // Ordinal tail: "twenty eighth", "hundred and first".
        if case .cardinal = kind, spanEnd < words.count, items[spanEnd - 1].trailing.isEmpty,
           let ordinal = ordinalUnits[words[spanEnd]] ?? ordinalTeens[words[spanEnd]] ?? ordinalTens[words[spanEnd]] {
            let base = value
            let combinable = (tens[words[spanEnd - 1]] != nil && ordinalUnits[words[spanEnd]] != nil)
                || (words[spanEnd - 1] == "hundred" || words[spanEnd - 1] == "and")
            if combinable {
                kind = .ordinal(base + ordinal)
                spanEnd += 1
            }
        }

        // Years: "nineteen sixty six", "twenty nineteen", "twenty twenty five".
        if case .cardinal = kind, let year = parseYear(words, items: items, from: start) {
            kind = .year(year.value)
            spanEnd = year.end
        }

        // Percent.
        if spanEnd < words.count, words[spanEnd] == "percent", items[spanEnd - 1].trailing.isEmpty {
            let number: String
            switch kind {
            case let .cardinal(value): number = grouped(value)
            case let .decimal(text): number = text
            case let .year(value): number = String(value)
            case .ordinal, .digits: return nil
            }
            return Span(start: start, end: spanEnd + 1, rendering: number + "%")
        }

        switch kind {
        case let .decimal(text):
            return Span(start: start, end: spanEnd, rendering: text)
        case let .year(value):
            return Span(start: start, end: spanEnd, rendering: String(value))
        case let .ordinal(value):
            return Span(start: start, end: spanEnd, rendering: ordinalText(value))
        case let .digits(text):
            return Span(start: start, end: spanEnd, rendering: text)
        case let .cardinal(value):
            if spelledSmall {
                // "six million" reads better than "6 million"; leave the small
                // multiplier alone unless the whole number is a plain cardinal.
                return nil
            }
            guard value >= 10 else { return nil }
            return Span(start: start, end: spanEnd, rendering: grouped(value))
        }
    }

    /// Parses a spelled-out cardinal. Returns the value, the exclusive end
    /// index, and whether the number is a small multiplier of a large scale
    /// ("six million") that should stay as words.
    private static func parseCardinal(
        _ words: [String],
        items: [Item],
        from start: Int
    ) -> (Int, Int, Bool)? {
        enum State { case start, unit, teen, tens, tensUnit, hundred, hundredAnd, scale, scaleAnd }
        var state = State.start
        var total = 0
        var current = 0
        var index = start
        var lastScale = Int.max
        var smallMultiplierOfScale = false
        var consumedAny = false

        func canContinue() -> Bool {
            index < words.count && (index == start || items[index - 1].trailing.isEmpty)
        }

        while canContinue() {
            let word = words[index]
            var advance = true
            switch state {
            case .start, .scale, .scaleAnd, .hundredAnd:
                if let unit = units[word] {
                    if state == .start, unit == 0, index + 1 < words.count,
                       units[words[index + 1]] != nil || teens[words[index + 1]] != nil {
                        return nil
                    }
                    current += unit
                    state = .unit
                } else if let teen = teens[word] {
                    current += teen
                    state = .teen
                } else if let ten = tens[word] {
                    current += ten
                    state = .tens
                } else if word == "hundred", state == .scale || state == .scaleAnd, current == 0 {
                    advance = false
                } else if word == "and", state == .scale {
                    state = .scaleAnd
                } else {
                    advance = false
                }
            case .unit, .teen, .tensUnit:
                if word == "hundred" {
                    current *= 100
                    state = .hundred
                } else if let scale = scales[word], scale < lastScale {
                    smallMultiplierOfScale = scale >= 1_000_000 && current < 10 && total == 0
                    total += current * scale
                    current = 0
                    lastScale = scale
                    state = .scale
                } else {
                    advance = false
                }
            case .tens:
                if let unit = units[word], unit > 0 {
                    current += unit
                    state = .tensUnit
                } else if let scale = scales[word], scale < lastScale {
                    total += current * scale
                    current = 0
                    lastScale = scale
                    state = .scale
                } else if word == "hundred" {
                    current *= 100
                    state = .hundred
                } else {
                    advance = false
                }
            case .hundred:
                if word == "and" {
                    state = .hundredAnd
                } else if let unit = units[word], unit > 0 {
                    current += unit
                    state = .unit
                } else if let teen = teens[word] {
                    current += teen
                    state = .teen
                } else if let ten = tens[word] {
                    current += ten
                    state = .tens
                } else if let scale = scales[word], scale < lastScale {
                    total += current * scale
                    current = 0
                    lastScale = scale
                    state = .scale
                } else {
                    advance = false
                }
            }
            if !advance { break }
            consumedAny = true
            index += 1
        }
        // A dangling "and" is not part of the number.
        if state == .hundredAnd || state == .scaleAnd {
            index -= 1
            state = .hundred
        }
        guard consumedAny else { return nil }
        // "zero" alone or "one" alone are words; the caller decides on size.
        return (total + current, index, smallMultiplierOfScale)
    }

    /// Digits after "point": either single digits in a row ("zero five" →
    /// "05", keeping leading zeros) or one teen/tens group ("thirty two").
    private static func parseFractionDigits(
        _ words: [String],
        items: [Item],
        from start: Int
    ) -> (String, Int)? {
        guard start < words.count else { return nil }
        var index = start
        var digits = ""
        while index < words.count, let unit = units[words[index]],
              index == start || items[index - 1].trailing.isEmpty {
            digits += String(unit)
            index += 1
        }
        if !digits.isEmpty {
            return (digits, index)
        }
        if let teen = teens[words[start]] {
            return (String(teen), start + 1)
        }
        if let ten = tens[words[start]] {
            var value = ten
            var end = start + 1
            if end < words.count, items[end - 1].trailing.isEmpty, let unit = units[words[end]], unit > 0 {
                value += unit
                end += 1
            }
            return (String(value), end)
        }
        return nil
    }

    private static func parseYear(
        _ words: [String],
        items: [Item],
        from start: Int
    ) -> (value: Int, end: Int)? {
        guard start + 1 < words.count, items[start].trailing.isEmpty else { return nil }
        let first = words[start]
        let second = words[start + 1]
        var century: Int?
        if let teen = teens[first], teen >= 11 { century = teen }
        if first == "twenty" { century = 20 }
        guard let century else { return nil }
        var value: Int
        var end = start + 2
        if let ten = tens[second] {
            value = century * 100 + ten
            if end < words.count, items[end - 1].trailing.isEmpty, let unit = units[words[end]], unit > 0 {
                value += unit
                end += 1
            }
        } else if let teen = teens[second] {
            // "nineteen fourteen", "twenty nineteen".
            value = century * 100 + teen
        } else if second == "hundred" {
            value = century * 100
        } else {
            return nil
        }
        // "twenty twenty" and "nineteen sixty six" are years; "twenty forty
        // hours" is not something people say, so no unit check is needed.
        guard value >= 1100, value <= 2099 else { return nil }
        return (value, end)
    }

    private static func parseOrdinalOnly(_ words: [String], items: [Item], from start: Int) -> Span? {
        let word = words[start]
        if let value = ordinalTeens[word] ?? ordinalTens[word] {
            return Span(start: start, end: start + 1, rendering: ordinalText(value))
        }
        if let value = ordinalUnits[word] {
            // "the fifth of September", "September fifth" are dates; "the first
            // Monday" or "a second" are not.
            let previous = start > 0 ? words[start - 1] : ""
            let next = start + 1 < words.count ? words[start + 1] : ""
            let afterNext = start + 2 < words.count ? words[start + 2] : ""
            let isDate = months.contains(previous)
                || (next == "of" && months.contains(afterNext))
            guard isDate else { return nil }
            return Span(start: start, end: start + 1, rendering: ordinalText(value))
        }
        return nil
    }

    // MARK: - Rendering

    private static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func ordinalText(_ value: Int) -> String {
        let suffix: String
        switch value % 100 {
        case 11, 12, 13: suffix = "th"
        default:
            switch value % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return grouped(value) + suffix
    }
}
