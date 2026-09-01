import Foundation

struct StreamingFinalizationDiagnostics: Sendable, Equatable {
    enum Strategy: String, Sendable {
        case notApplicable
        case anchoredRanges
        case wholeTranscript
    }

    enum FullPassReason: String, Sendable {
        case postProcessingDisabled
        case noCompletedSegments
        case streamingSegmentFailure
        case noSafeAnchors
        case rangePolishingFailure
        case reconciledCandidateRejected
    }

    let strategy: Strategy
    let fullPassReason: FullPassReason?
    let completedSegmentCount: Int
    let reusedSegmentCount: Int
    let reusedWordCount: Int
    let reprocessedWordCount: Int
    let reprocessedRangeCount: Int

    static let notApplicable = Self(
        strategy: .notApplicable,
        fullPassReason: nil,
        completedSegmentCount: 0,
        reusedSegmentCount: 0,
        reusedWordCount: 0,
        reprocessedWordCount: 0,
        reprocessedRangeCount: 0
    )
}

struct LiveDictationResult: Sendable {
    let rawTranscript: String
    let transcript: String
    let finalizationDiagnostics: StreamingFinalizationDiagnostics

    init(
        rawTranscript: String,
        transcript: String,
        finalizationDiagnostics: StreamingFinalizationDiagnostics = .notApplicable
    ) {
        self.rawTranscript = rawTranscript
        self.transcript = transcript
        self.finalizationDiagnostics = finalizationDiagnostics
    }
}

/// Polishes stable Parakeet segments while recording. Every polished segment
/// owns a disjoint source span; adjacent spans are supplied to Qwen only as
/// read-only context, so overlap can never duplicate pasted text.
actor StreamingTranscriptPolisher {
    private struct Segment: Sendable {
        let source: String
        let polished: String
    }

    private let isEnabled: Bool
    private let model: PostProcessingModel
    private let processor: any TranscriptPolishing

    private var polishedSegments: [Segment] = []
    private var pendingSegment: String?
    private var previousSourceContext = ""
    private var encounteredFailure = false

    init(
        isEnabled: Bool,
        model: PostProcessingModel,
        processor: any TranscriptPolishing
    ) {
        self.isEnabled = isEnabled
        self.model = model
        self.processor = processor
    }

    func consumeStableSegment(_ rawSegment: String) async {
        guard isEnabled, !encounteredFailure else { return }
        let segment = TranscriptCleaner.clean(rawSegment)
        guard !segment.isEmpty else { return }

        // Own each complete sentence independently. A final ASR revision can
        // then invalidate only that sentence instead of throwing away an entire
        // multi-sentence checkpoint that Qwen already polished.
        let sentenceSegments = StreamingTranscriptPolicy.sentenceSegments(
            in: segment
        )
        for (index, currentSegment) in sentenceSegments.enumerated() {
            let followingSegment = index + 1 < sentenceSegments.count
                ? sentenceSegments[index + 1]
                : ""

            // An unfinished segment waits for the next Parakeet window. That
            // next window becomes a right-side context halo, while output
            // ownership stays exclusively with the pending segment.
            if let pendingSegment {
                await process(
                    pendingSegment,
                    followingContext: StreamingTranscriptPolicy.leadingContext(
                        of: currentSegment
                    )
                )
                self.pendingSegment = nil
            }

            guard !encounteredFailure else { return }
            if StreamingTranscriptPolicy.endsAtStrongBoundary(currentSegment) {
                await process(
                    currentSegment,
                    followingContext: StreamingTranscriptPolicy.leadingContext(
                        of: followingSegment
                    )
                )
            } else {
                pendingSegment = currentSegment
            }
        }
    }

    func finalize(rawTranscript: String) async -> LiveDictationResult {
        let rawTranscript = TranscriptCleaner.clean(rawTranscript)
        guard isEnabled, !rawTranscript.isEmpty else {
            return LiveDictationResult(
                rawTranscript: rawTranscript,
                transcript: rawTranscript,
                finalizationDiagnostics: StreamingFinalizationDiagnostics(
                    strategy: .notApplicable,
                    fullPassReason: .postProcessingDisabled,
                    completedSegmentCount: polishedSegments.count,
                    reusedSegmentCount: 0,
                    reusedWordCount: 0,
                    reprocessedWordCount: 0,
                    reprocessedRangeCount: 0
                )
            )
        }

        guard !encounteredFailure else {
            return await wholeTranscriptResult(
                rawTranscript,
                reason: .streamingSegmentFailure
            )
        }
        guard !polishedSegments.isEmpty else {
            return await wholeTranscriptResult(
                rawTranscript,
                reason: .noCompletedSegments
            )
        }

        guard let plan = StreamingTranscriptReconciler.anchoredPlan(
            in: rawTranscript,
            processedSegments: polishedSegments.map(\.source)
        ) else {
            return await wholeTranscriptResult(
                rawTranscript,
                reason: .noSafeAnchors
            )
        }

        var outputs: [String] = []
        outputs.reserveCapacity(plan.pieces.count)
        do {
            for piece in plan.pieces {
                switch piece {
                case let .reusedSegment(index, _):
                    outputs.append(polishedSegments[index].polished)
                case let .unprocessedRange(
                    source,
                    precedingContext,
                    followingContext,
                    _
                ):
                    outputs.append(
                        try await polishFinalRange(
                            source,
                            precedingContext: precedingContext,
                            followingContext: followingContext
                        )
                    )
                }
            }
        } catch {
            return await wholeTranscriptResult(
                rawTranscript,
                reason: .rangePolishingFailure
            )
        }

        let candidate = outputs
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard TranscriptPolishPolicy.isStreamingEditAcceptable(
            candidate,
            for: rawTranscript
        ) else {
            return await wholeTranscriptResult(
                rawTranscript,
                reason: .reconciledCandidateRejected
            )
        }

        return LiveDictationResult(
            rawTranscript: rawTranscript,
            transcript: candidate,
            finalizationDiagnostics: StreamingFinalizationDiagnostics(
                strategy: .anchoredRanges,
                fullPassReason: nil,
                completedSegmentCount: polishedSegments.count,
                reusedSegmentCount: plan.reusedSegmentCount,
                reusedWordCount: plan.reusedWordCount,
                reprocessedWordCount: plan.reprocessedWordCount,
                reprocessedRangeCount: plan.reprocessedRangeCount
            )
        )
    }

    private func polishFinalRange(
        _ source: String,
        precedingContext: String,
        followingContext: String
    ) async throws -> String {
        if source.count > TranscriptPolishPolicy.maximumChunkCharacters {
            return try await processor.polish(source, using: model)
        }
        return try await processor.polishStreamingSegment(
            source,
            precedingContext: precedingContext,
            followingContext: followingContext,
            using: model
        )
    }

    private func wholeTranscriptResult(
        _ rawTranscript: String,
        reason: StreamingFinalizationDiagnostics.FullPassReason
    ) async -> LiveDictationResult {
        LiveDictationResult(
            rawTranscript: rawTranscript,
            transcript: await polishWholeTranscriptOrUseRaw(rawTranscript),
            finalizationDiagnostics: StreamingFinalizationDiagnostics(
                strategy: .wholeTranscript,
                fullPassReason: reason,
                completedSegmentCount: polishedSegments.count,
                reusedSegmentCount: 0,
                reusedWordCount: 0,
                reprocessedWordCount: StreamingTranscriptReconciler.wordCount(
                    in: rawTranscript
                ),
                reprocessedRangeCount: rawTranscript.isEmpty ? 0 : 1
            )
        )
    }

    private func process(
        _ source: String,
        followingContext: String
    ) async {
        do {
            let polished = try await processor.polishStreamingSegment(
                source,
                precedingContext: StreamingTranscriptPolicy.trailingContext(
                    of: previousSourceContext
                ),
                followingContext: followingContext,
                using: model
            )
            polishedSegments.append(
                Segment(source: source, polished: polished)
            )
            previousSourceContext = source
        } catch {
            // The recording continues uninterrupted. finalize() will detect the
            // flag and retry the complete transcript through the normal path.
            encounteredFailure = true
        }
    }

    private func polishWholeTranscriptOrUseRaw(_ transcript: String) async -> String {
        do {
            return try await processor.polish(transcript, using: model)
        } catch {
            return transcript
        }
    }

}

enum StreamingTranscriptPolicy {
    private static let maximumContextCharacters = 320
    private static let strongTerminators: Set<Character> = [
        ".", "?", "!", "…", "。", "？", "！"
    ]
    private static let closingCharacters: Set<Character> = [
        "\"", "'", "”", "’", ")", "]", "}", "»", "›"
    ]

    static func endsAtStrongBoundary(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var characters = Array(trimmed)
        while let last = characters.last, closingCharacters.contains(last) {
            characters.removeLast()
        }
        guard let last = characters.last else { return false }
        return strongTerminators.contains(last)
    }

    /// Returns only sentence text that has at least one later strong boundary.
    /// Holding the newest apparent sentence avoids committing abbreviations or
    /// punctuation that cumulative ASR may revise at the next checkpoint.
    static func stablePrefix(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let characters = Array(trimmed)
        guard !characters.isEmpty else { return "" }

        let boundaries = strongBoundaryEnds(in: characters)

        guard boundaries.count >= 2 else { return "" }
        let stableEnd = boundaries[boundaries.count - 2]
        return String(characters[..<stableEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Consecutive cumulative ASR snapshots provide stronger evidence than a
    /// single snapshot. Once their shared prefix includes a complete sentence,
    /// that newest confirmed sentence can be polished immediately instead of
    /// holding an extra sentence until release.
    static func completeSentencePrefix(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let characters = Array(trimmed)
        guard let completeEnd = strongBoundaryEnds(in: characters).last else {
            return ""
        }
        return String(characters[..<completeEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sentenceSegments(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let characters = Array(trimmed)
        guard !characters.isEmpty else { return [] }

        let boundaries = strongBoundaryEnds(in: characters)
        var segments: [String] = []
        var segmentStart = 0
        for segmentEnd in boundaries {
            let segment = String(characters[segmentStart..<segmentEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.isEmpty { segments.append(segment) }
            segmentStart = segmentEnd
        }

        if segmentStart < characters.count {
            let remainder = String(characters[segmentStart...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainder.isEmpty { segments.append(remainder) }
        }
        return segments
    }

    static func leadingContext(of text: String) -> String {
        contextSlice(text, fromEnd: false)
    }

    static func trailingContext(of text: String) -> String {
        contextSlice(text, fromEnd: true)
    }

    private static func contextSlice(_ text: String, fromEnd: Bool) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumContextCharacters else { return trimmed }

        if fromEnd {
            let tentativeStart = trimmed.index(
                trimmed.endIndex,
                offsetBy: -maximumContextCharacters
            )
            let suffix = trimmed[tentativeStart...]
            guard let boundary = suffix.firstIndex(where: \.isWhitespace) else {
                return String(suffix)
            }
            return String(suffix[boundary...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let tentativeEnd = trimmed.index(
            trimmed.startIndex,
            offsetBy: maximumContextCharacters
        )
        let prefix = trimmed[..<tentativeEnd]
        guard let boundary = prefix.lastIndex(where: \.isWhitespace) else {
            return String(prefix)
        }
        return String(prefix[...boundary])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func strongBoundaryEnds(in characters: [Character]) -> [Int] {
        var boundaries: [Int] = []
        for index in characters.indices where strongTerminators.contains(characters[index]) {
            var cursor = index + 1
            while cursor < characters.count,
                  closingCharacters.contains(characters[cursor]) {
                cursor += 1
            }
            if cursor == characters.count || characters[cursor].isWhitespace {
                boundaries.append(cursor)
            }
        }
        return boundaries
    }
}

enum StreamingTranscriptReconciler {
    struct AnchoredPlan: Sendable {
        enum Piece: Sendable {
            case reusedSegment(index: Int, sourceWordCount: Int)
            case unprocessedRange(
                source: String,
                precedingContext: String,
                followingContext: String,
                sourceWordCount: Int
            )
        }

        let pieces: [Piece]
        let reusedSegmentCount: Int
        let reusedWordCount: Int
        let reprocessedWordCount: Int
        let reprocessedRangeCount: Int
    }

    private struct Anchor {
        let segmentIndex: Int
        let finalWordRange: Range<Int>
    }

    private struct Word {
        let normalized: String
        let range: Range<String.Index>
    }

    /// Reuses every completed Qwen segment whose complete normalized word span
    /// still exists in the final ASR transcript. Revised gaps between those
    /// anchors are returned as independent ranges for Qwen to process again.
    /// Ambiguous out-of-position matches are never used as anchors.
    static func anchoredPlan(
        in finalTranscript: String,
        processedSegments: [String]
    ) -> AnchoredPlan? {
        let finalWords = words(in: finalTranscript)
        guard !finalWords.isEmpty, !processedSegments.isEmpty else { return nil }

        let normalizedFinalWords = finalWords.map(\.normalized)
        var anchors: [Anchor] = []
        var searchCursor = 0

        for (segmentIndex, segment) in processedSegments.enumerated() {
            let segmentWords = words(in: segment).map(\.normalized)
            guard !segmentWords.isEmpty else { continue }

            let occurrences = exactOccurrences(
                of: segmentWords,
                in: normalizedFinalWords,
                startingAt: searchCursor
            )
            guard !occurrences.isEmpty else { continue }

            let anchorStart: Int
            if occurrences[0] == searchCursor {
                anchorStart = searchCursor
            } else {
                // Away from the expected cursor, short or repeated phrases are
                // too weak to identify ownership safely.
                guard segmentWords.count >= 4, occurrences.count == 1 else {
                    continue
                }
                anchorStart = occurrences[0]
            }

            let anchorEnd = anchorStart + segmentWords.count
            anchors.append(
                Anchor(
                    segmentIndex: segmentIndex,
                    finalWordRange: anchorStart..<anchorEnd
                )
            )
            searchCursor = anchorEnd
        }

        let reusedWordCount = anchors.reduce(0) {
            $0 + $1.finalWordRange.count
        }
        guard reusedWordCount >= min(4, finalWords.count) else { return nil }

        var pieces: [AnchoredPlan.Piece] = []
        var finalWordCursor = 0

        func appendUnprocessedRange(_ wordRange: Range<Int>) {
            guard !wordRange.isEmpty else { return }
            let startIndex = wordRange.lowerBound == 0
                ? finalTranscript.startIndex
                : finalWords[wordRange.lowerBound].range.lowerBound
            let endIndex = wordRange.upperBound == finalWords.count
                ? finalTranscript.endIndex
                : finalWords[wordRange.upperBound].range.lowerBound
            let source = String(finalTranscript[startIndex..<endIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else { return }

            let preceding = String(finalTranscript[..<startIndex])
            let following = String(finalTranscript[endIndex...])
            pieces.append(
                .unprocessedRange(
                    source: source,
                    precedingContext: StreamingTranscriptPolicy.trailingContext(
                        of: preceding
                    ),
                    followingContext: StreamingTranscriptPolicy.leadingContext(
                        of: following
                    ),
                    sourceWordCount: wordRange.count
                )
            )
        }

        for anchor in anchors {
            appendUnprocessedRange(finalWordCursor..<anchor.finalWordRange.lowerBound)
            pieces.append(
                .reusedSegment(
                    index: anchor.segmentIndex,
                    sourceWordCount: anchor.finalWordRange.count
                )
            )
            finalWordCursor = anchor.finalWordRange.upperBound
        }
        appendUnprocessedRange(finalWordCursor..<finalWords.count)

        let reprocessedWordCount = pieces.reduce(0) { count, piece in
            guard case let .unprocessedRange(_, _, _, words) = piece else {
                return count
            }
            return count + words
        }
        let reprocessedRangeCount = pieces.count(where: { piece in
            if case .unprocessedRange = piece { return true }
            return false
        })

        return AnchoredPlan(
            pieces: pieces,
            reusedSegmentCount: anchors.count,
            reusedWordCount: reusedWordCount,
            reprocessedWordCount: reprocessedWordCount,
            reprocessedRangeCount: reprocessedRangeCount
        )
    }

    static func wordCount(in text: String) -> Int {
        words(in: text).count
    }

    private static func exactOccurrences(
        of needle: [String],
        in haystack: [String],
        startingAt searchStart: Int
    ) -> [Int] {
        guard !needle.isEmpty,
              searchStart >= 0,
              searchStart <= haystack.count,
              needle.count <= haystack.count - searchStart else {
            return []
        }

        let finalStart = haystack.count - needle.count
        guard searchStart <= finalStart else { return [] }

        var result: [Int] = []
        for candidateStart in searchStart...finalStart {
            let candidateEnd = candidateStart + needle.count
            if haystack[candidateStart..<candidateEnd].elementsEqual(needle) {
                result.append(candidateStart)
            }
        }
        return result
    }

    /// Returns the final transcript suffix that has not already been processed,
    /// but only when the processed text is still an exact normalized prefix.
    /// Punctuation and capitalization may change during final token decoding;
    /// meaningful word changes force a full-pass fallback.
    static func unprocessedSuffix(
        in finalTranscript: String,
        afterProcessedPrefix processedPrefix: String
    ) -> String? {
        let processedWords = words(in: processedPrefix).map(\.normalized)
        let finalWords = words(in: finalTranscript)

        guard !processedWords.isEmpty else {
            return finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard processedWords.count <= finalWords.count else { return nil }
        guard zip(processedWords, finalWords).allSatisfy({ lhs, rhs in
            lhs == rhs.normalized
        }) else {
            return nil
        }

        guard processedWords.count < finalWords.count else { return "" }
        let suffixStart = finalWords[processedWords.count].range.lowerBound
        return String(finalTranscript[suffixStart...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the word prefix shared by two consecutive cumulative ASR
    /// snapshots, retaining a small uncommitted tail. Unlike fixed time
    /// windows, this can never split a recognized word at an audio seam.
    static func confirmedPrefix(
        in currentTranscript: String,
        against previousTranscript: String,
        holdingBack holdbackWords: Int
    ) -> String {
        let currentWords = words(in: currentTranscript)
        let previousWords = words(in: previousTranscript)
        guard !currentWords.isEmpty, !previousWords.isEmpty else { return "" }

        var commonWordCount = 0
        while commonWordCount < currentWords.count,
              commonWordCount < previousWords.count,
              currentWords[commonWordCount].normalized
                == previousWords[commonWordCount].normalized {
            commonWordCount += 1
        }

        let confirmedWordCount = max(0, commonWordCount - max(0, holdbackWords))
        guard confirmedWordCount > 0 else { return "" }

        let prefixEnd: String.Index
        if confirmedWordCount < currentWords.count {
            prefixEnd = currentWords[confirmedWordCount].range.lowerBound
        } else {
            prefixEnd = currentTranscript.endIndex
        }
        return String(currentTranscript[..<prefixEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func words(in text: String) -> [Word] {
        var result: [Word] = []
        var wordStart: String.Index?
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character.isNumber {
                if wordStart == nil {
                    wordStart = index
                }
            } else if let start = wordStart {
                let range = start..<index
                result.append(
                    Word(
                        normalized: text[range].lowercased(),
                        range: range
                    )
                )
                wordStart = nil
            }
            index = text.index(after: index)
        }

        if let start = wordStart {
            let range = start..<text.endIndex
            result.append(
                Word(
                    normalized: text[range].lowercased(),
                    range: range
                )
            )
        }
        return result
    }
}
