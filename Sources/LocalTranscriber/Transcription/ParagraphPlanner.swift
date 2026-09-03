import Foundation

/// Splits a long dictation into paragraphs of a few sentences each.
///
/// Neither of the two obvious signals works with the models and speakers this
/// app serves: small language models asked for paragraph positions list
/// every sentence or none, and a person dictating pauses mid-sentence to
/// think rather than between thoughts. Measured against human-edited
/// transcripts, breaking about every three sentences lands within one
/// sentence of the editor's break for roughly two thirds of paragraphs, which
/// a wall of text never does. The plan prefers not to start a paragraph with a
/// word that continues the previous sentence ("He", "It", "Then", "Also").
enum ParagraphPlanner {
    static let sentencesPerParagraph = 3
    static let minimumSentencesPerParagraph = 2
    /// Shorter dictations stay a single paragraph.
    static let minimumSentences = 8
    static let minimumWords = 120

    static let continuationWords: Set<String> = [
        "he", "she", "it", "they", "this", "that", "these", "those", "his", "her", "their", "its",
        "then", "and", "but", "so", "because", "which", "also", "or", "hes", "shes", "theyre",
        "thats", "theres", "for", "in", "however", "otherwise", "therefore", "plus", "yet",
    ]

    static func paragraphStarts(in transcript: String) -> [Int] {
        let sentences = StreamingTranscriptPolicy.sentenceSegments(in: transcript)
        guard sentences.count >= minimumSentences else { return [] }
        let words = sentences.reduce(0) { $0 + $1.split(whereSeparator: \.isWhitespace).count }
        guard words >= minimumWords else { return [] }

        var starts: [Int] = []
        var last = 0
        while true {
            var candidate = last + sentencesPerParagraph
            guard sentences.count - candidate >= minimumSentencesPerParagraph else { break }
            if continues(sentences[candidate]) {
                for alternative in [candidate + 1, candidate - 1]
                where alternative - last >= minimumSentencesPerParagraph
                    && sentences.count - alternative >= minimumSentencesPerParagraph
                    && !continues(sentences[alternative]) {
                    candidate = alternative
                    break
                }
            }
            starts.append(candidate)
            last = candidate
        }
        return starts
    }

    private static func continues(_ sentence: String) -> Bool {
        guard let first = sentence.split(whereSeparator: \.isWhitespace).first else { return false }
        let word = first.lowercased().filter { $0.isLetter }
        return continuationWords.contains(word)
    }
}
