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

/// Text that cumulative ASR has committed while recording, together with the
/// neighbouring transcript that Qwen may read but must never return.
struct StreamingStableRange: Sendable, Equatable {
    let source: String
    let precedingContext: String
    let followingContext: String
}

/// One Parakeet pass made by the streaming loop.
struct StreamingCheckpointEvent: Sendable {
    enum Kind: String, Sendable {
        /// Cumulative transcription while recording.
        case checkpoint
        /// Authoritative whole-recording pass after release.
        case finalPass
    }

    let kind: Kind
    let audioSeconds: Double
    let transcriptionSeconds: Double
    let startedAt: ContinuousClock.Instant
    let finishedAt: ContinuousClock.Instant
}

/// Polishes stable Parakeet segments while recording. Every polished segment
/// owns a disjoint source span; adjacent spans are supplied to Qwen only as
/// read-only context, so overlap can never duplicate pasted text.
///
/// Segments are queued and polished by a single background worker so the
/// audio loop never waits for the language model. At release, only the
/// in-flight call is awaited; queued segments that never started are folded
/// into the final reconciliation, where adjacent ones merge into one call.
actor StreamingTranscriptPolisher {
    private struct Segment: Sendable {
        let source: String
        let polished: String
    }

    private struct QueuedSegment: Sendable {
        let source: String
        let precedingContext: String
        let followingContext: String
    }

    private static let finalRangeChunkCharacters = 600

    /// Fragments shorter than this, such as the "Bridge Brid St." left behind
    /// by an abbreviation period, are polished together with the sentence
    /// that follows them instead of on their own.
    private static let minimumSegmentWords = 4

    private let isEnabled: Bool
    private let model: PostProcessingModel
    private let processor: any TranscriptPolishing

    private var polishedSegments: [Segment] = []
    private var queue: [QueuedSegment] = []
    private var pendingSegment: QueuedSegment?
    private var lastQueuedSource = ""
    private var worker: Task<Void, Never>?
    private var isFinalizing = false
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

    /// Accepts contiguous stable text. Context halos are derived from the
    /// previously queued segment and from the sentences within this call.
    func consumeStableSegment(_ rawSegment: String) {
        consumeStableSegment(
            StreamingStableRange(
                source: rawSegment,
                precedingContext: StreamingTranscriptPolicy.trailingContext(
                    of: lastQueuedSource
                ),
                followingContext: ""
            )
        )
    }

    /// Queues every complete sentence in the range for polishing and returns
    /// immediately. The range's context halos are used only where this call
    /// has no neighbouring sentence of its own.
    func consumeStableSegment(_ range: StreamingStableRange) {
        guard isEnabled, !encounteredFailure, !isFinalizing else { return }
        let segment = TranscriptCleaner.clean(range.source)
        guard !segment.isEmpty else { return }

        // Own each complete sentence independently. A final ASR revision can
        // then invalidate only that sentence instead of throwing away an entire
        // multi-sentence checkpoint that Qwen already polished.
        var sentences = StreamingTranscriptPolicy.sentenceSegments(
            in: segment,
            mergingSegmentsShorterThan: Self.minimumSegmentWords
        )
        var precedingContext = StreamingTranscriptPolicy.trailingContext(
            of: range.precedingContext
        )

        if let pending = pendingSegment, let first = sentences.first {
            pendingSegment = nil
            precedingContext = pending.precedingContext
            if StreamingTranscriptReconciler.wordCount(in: pending.source)
                < Self.minimumSegmentWords {
                // A short fragment joins the sentence that follows it.
                sentences[0] = pending.source + " " + first
            } else {
                // An unfinished segment waited for the next stable text. That
                // text becomes a right-side context halo, while output
                // ownership stays exclusively with the pending segment.
                enqueue(
                    QueuedSegment(
                        source: pending.source,
                        precedingContext: pending.precedingContext,
                        followingContext: StreamingTranscriptPolicy.leadingContext(
                            of: first
                        )
                    )
                )
                precedingContext = StreamingTranscriptPolicy.trailingContext(
                    of: pending.source
                )
            }
        }

        for (index, sentence) in sentences.enumerated() {
            let isLast = index + 1 == sentences.count
            let followingContext = isLast
                ? StreamingTranscriptPolicy.leadingContext(of: range.followingContext)
                : StreamingTranscriptPolicy.leadingContext(of: sentences[index + 1])
            let queued = QueuedSegment(
                source: sentence,
                precedingContext: precedingContext,
                followingContext: followingContext
            )
            let isShort = StreamingTranscriptReconciler.wordCount(in: sentence)
                < Self.minimumSegmentWords
            if isLast, isShort {
                pendingSegment = queued
            } else if StreamingTranscriptPolicy.endsAtStrongBoundary(sentence)
                || !followingContext.isEmpty {
                enqueue(queued)
            } else {
                pendingSegment = queued
            }
            precedingContext = StreamingTranscriptPolicy.trailingContext(of: sentence)
        }
    }

    func finalize(rawTranscript: String) async -> LiveDictationResult {
        isFinalizing = true
        // Segments that never started are cheaper to polish as merged final
        // ranges than as individual queued calls, so drop them here.
        queue.removeAll()
        pendingSegment = nil
        await worker?.value

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

    /// Stops polishing a discarded recording. Queued segments are dropped and
    /// no further segments are accepted; an in-flight call finishes on its own.
    func cancel() {
        isFinalizing = true
        queue.removeAll()
        pendingSegment = nil
    }

    /// Waits until every queued segment has been polished. Used by tests;
    /// production code never blocks the audio loop on the language model.
    func waitForQueuedWork() async {
        while let worker {
            await worker.value
            if self.worker == nil { return }
        }
    }

    private func enqueue(_ segment: QueuedSegment) {
        queue.append(segment)
        lastQueuedSource = segment.source
        guard worker == nil else { return }
        worker = Task { await self.drainQueue() }
    }

    private func drainQueue() async {
        while !isFinalizing, !encounteredFailure, !queue.isEmpty {
            let segment = queue.removeFirst()
            await process(segment)
        }
        worker = nil
    }

    private func process(_ segment: QueuedSegment) async {
        do {
            let polished = try await processor.polishStreamingSegment(
                segment.source,
                precedingContext: segment.precedingContext,
                followingContext: segment.followingContext,
                using: model
            )
            polishedSegments.append(
                Segment(source: segment.source, polished: polished)
            )
        } catch {
            // The recording continues uninterrupted. finalize() will detect the
            // flag and retry the complete transcript through the normal path.
            encounteredFailure = true
        }
    }

    /// Polishes a final range a few sentences at a time. The tail of a
    /// recording is normally one call; a long backlog is split at sentence
    /// boundaries so the small model edits instead of summarizing.
    private func polishFinalRange(
        _ source: String,
        precedingContext: String,
        followingContext: String
    ) async throws -> String {
        let pieces = TranscriptPolishPolicy.chunks(
            from: source,
            maximumCharacters: Self.finalRangeChunkCharacters
        )
        guard pieces.count > 1 else {
            return try await processor.polishStreamingSegment(
                source,
                precedingContext: precedingContext,
                followingContext: followingContext,
                using: model
            )
        }

        var outputs: [String] = []
        outputs.reserveCapacity(pieces.count)
        for (index, piece) in pieces.enumerated() {
            let preceding = index == 0
                ? precedingContext
                : StreamingTranscriptPolicy.trailingContext(of: pieces[index - 1])
            let following = index + 1 == pieces.count
                ? followingContext
                : StreamingTranscriptPolicy.leadingContext(of: pieces[index + 1])
            outputs.append(
                try await processor.polishStreamingSegment(
                    piece,
                    precedingContext: preceding,
                    followingContext: following,
                    using: model
                )
            )
        }
        return outputs.joined(separator: " ")
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

    private func polishWholeTranscriptOrUseRaw(_ transcript: String) async -> String {
        do {
            return try await processor.polish(transcript, using: model)
        } catch {
            return transcript
        }
    }
}

/// Tracks which sentences have already been handed to the polisher so each
/// cumulative ASR checkpoint emits only new or revised text, in transcript
/// order. A revised sentence is simply emitted again; stale versions are
/// ignored by the exact-word anchoring at release.
struct StreamingEmissionTracker: Sendable {
    private(set) var emittedSegments: [String] = []

    mutating func newRanges(in stableText: String) -> [StreamingStableRange] {
        let text = stableText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        guard let plan = StreamingTranscriptReconciler.anchoredPlan(
            in: text,
            processedSegments: emittedSegments
        ) else {
            emittedSegments = StreamingTranscriptPolicy.sentenceSegments(in: text)
            return [
                StreamingStableRange(
                    source: text,
                    precedingContext: "",
                    followingContext: ""
                ),
            ]
        }

        var ranges: [StreamingStableRange] = []
        var orderedSegments: [String] = []
        for piece in plan.pieces {
            switch piece {
            case let .reusedSegment(index, _):
                orderedSegments.append(emittedSegments[index])
            case let .unprocessedRange(source, precedingContext, followingContext, _):
                ranges.append(
                    StreamingStableRange(
                        source: source,
                        precedingContext: precedingContext,
                        followingContext: followingContext
                    )
                )
                orderedSegments.append(
                    contentsOf: StreamingTranscriptPolicy.sentenceSegments(in: source)
                )
            }
        }
        emittedSegments = orderedSegments
        return ranges
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

    static func isStrongTerminator(_ character: Character) -> Bool {
        strongTerminators.contains(character)
    }

    static func isClosingCharacter(_ character: Character) -> Bool {
        closingCharacters.contains(character)
    }

    static func endsAtStrongBoundary(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var characters = Array(trimmed)
        while let last = characters.last, closingCharacters.contains(last) {
            characters.removeLast()
        }
        guard let last = characters.last else { return false }
        return strongTerminators.contains(last)
    }

    /// Returns the complete sentences of a cumulative ASR snapshot that end at
    /// least `minimumTrailingWords` words before the snapshot's edge. A cut
    /// mid-word can only corrupt the final words of a snapshot, so a sentence
    /// boundary followed by several more words was heard in full.
    static func committedSentencePrefix(
        of text: String,
        minimumTrailingWords: Int
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let characters = Array(trimmed)
        guard !characters.isEmpty else { return "" }

        for boundary in strongBoundaryEnds(in: characters).reversed() {
            let trailing = String(characters[boundary...])
            guard StreamingTranscriptReconciler.wordCount(in: trailing)
                >= minimumTrailingWords else { continue }
            return String(characters[..<boundary])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    /// Splits text into sentences, then joins any sentence with fewer than
    /// `minimumWords` words onto the sentence that follows it.
    static func sentenceSegments(
        in text: String,
        mergingSegmentsShorterThan minimumWords: Int
    ) -> [String] {
        var merged: [String] = []
        var carried = ""
        for sentence in sentenceSegments(in: text) {
            let combined = carried.isEmpty ? sentence : carried + " " + sentence
            if StreamingTranscriptReconciler.wordCount(in: combined) < minimumWords {
                carried = combined
            } else {
                merged.append(combined)
                carried = ""
            }
        }
        if !carried.isEmpty {
            merged.append(carried)
        }
        return merged
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

    /// Whether the text has a sentence boundary immediately after the word
    /// ending at `wordEnd`: only punctuation and closing quotes may follow
    /// before whitespace or the end of the text, and one of them must be a
    /// strong terminator. "1.10.32" therefore has no boundary after "1".
    static func hasStrongBoundary(after wordEnd: String.Index, in text: String) -> Bool {
        var cursor = wordEnd
        var sawTerminator = false
        while cursor < text.endIndex {
            let character = text[cursor]
            if character.isWhitespace { break }
            if strongTerminators.contains(character) {
                sawTerminator = true
            } else if character.isLetter || character.isNumber {
                return false
            }
            cursor = text.index(after: cursor)
        }
        return sawTerminator || cursor == text.endIndex
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
    /// still exists in the final ASR transcript at a matching sentence
    /// boundary. Revised gaps between those anchors are returned as
    /// independent ranges for Qwen to process again. Ambiguous out-of-position
    /// matches are never used as anchors.
    ///
    /// Segments are first matched in their emission order; segments that were
    /// re-emitted later (a revised sentence) are then placed by their unique
    /// occurrence, so the plan always follows transcript order.
    static func anchoredPlan(
        in finalTranscript: String,
        processedSegments: [String]
    ) -> AnchoredPlan? {
        let finalWords = words(in: finalTranscript)
        guard !finalWords.isEmpty, !processedSegments.isEmpty else { return nil }

        let normalizedFinalWords = finalWords.map(\.normalized)
        let segmentWordLists = processedSegments.map { words(in: $0).map(\.normalized) }
        var anchors: [Anchor] = []
        var searchCursor = 0
        var deferredSegments: [Int] = []

        func isValidAnchor(segmentIndex: Int, start: Int) -> Bool {
            let range = start..<(start + segmentWordLists[segmentIndex].count)
            guard !anchors.contains(where: { $0.finalWordRange.overlaps(range) }) else {
                return false
            }
            return boundariesAgree(
                segment: processedSegments[segmentIndex],
                finalTranscript: finalTranscript,
                finalWords: finalWords,
                range: range
            )
        }

        for (segmentIndex, segmentWords) in segmentWordLists.enumerated() {
            guard !segmentWords.isEmpty else { continue }

            let occurrences = exactOccurrences(
                of: segmentWords,
                in: normalizedFinalWords,
                startingAt: searchCursor
            )
            let anchorStart: Int
            if let first = occurrences.first,
               first == searchCursor,
               isValidAnchor(segmentIndex: segmentIndex, start: first) {
                anchorStart = first
            } else if segmentWords.count >= 4,
                      occurrences.count == 1,
                      isValidAnchor(segmentIndex: segmentIndex, start: occurrences[0]) {
                // Away from the expected cursor, short or repeated phrases are
                // too weak to identify ownership safely.
                anchorStart = occurrences[0]
            } else {
                deferredSegments.append(segmentIndex)
                continue
            }

            let anchorEnd = anchorStart + segmentWords.count
            anchors.append(
                Anchor(segmentIndex: segmentIndex, finalWordRange: anchorStart..<anchorEnd)
            )
            searchCursor = anchorEnd
        }

        for segmentIndex in deferredSegments {
            let segmentWords = segmentWordLists[segmentIndex]
            guard segmentWords.count >= 4 else { continue }
            let occurrences = exactOccurrences(
                of: segmentWords,
                in: normalizedFinalWords,
                startingAt: 0
            )
            guard occurrences.count == 1,
                  isValidAnchor(segmentIndex: segmentIndex, start: occurrences[0]) else {
                continue
            }
            anchors.append(
                Anchor(
                    segmentIndex: segmentIndex,
                    finalWordRange: occurrences[0]..<(occurrences[0] + segmentWords.count)
                )
            )
        }
        guard !anchors.isEmpty else { return nil }
        anchors.sort { $0.finalWordRange.lowerBound < $1.finalWordRange.lowerBound }

        let reusedWordCount = anchors.reduce(0) {
            $0 + $1.finalWordRange.count
        }

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

    /// A polished segment was capitalized and punctuated as a sentence of its
    /// own. Reusing it is only safe where the final transcript also starts a
    /// sentence at its first word and ends one at its last word, exactly when
    /// the segment does; otherwise "a treatise." would be pasted mid-sentence.
    private static func boundariesAgree(
        segment: String,
        finalTranscript: String,
        finalWords: [Word],
        range: Range<Int>
    ) -> Bool {
        let startsSentence = range.lowerBound == 0
            || StreamingTranscriptPolicy.hasStrongBoundary(
                after: finalWords[range.lowerBound - 1].range.upperBound,
                in: finalTranscript
            )
        guard startsSentence else { return false }

        let finalEndsSentence = StreamingTranscriptPolicy.hasStrongBoundary(
            after: finalWords[range.upperBound - 1].range.upperBound,
            in: finalTranscript
        )
        return finalEndsSentence == StreamingTranscriptPolicy.endsAtStrongBoundary(segment)
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
