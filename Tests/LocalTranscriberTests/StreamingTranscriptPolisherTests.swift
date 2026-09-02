import XCTest
@testable import LocalTranscriber

final class StreamingTranscriptPolisherTests: XCTestCase {
    func testEmissionTrackerEmitsOnlyNewSentencesInOrder() {
        var tracker = StreamingEmissionTracker()

        let first = tracker.newRanges(in: "First sentence is here. Second sentence follows.")
        XCTAssertEqual(first.map(\.source), ["First sentence is here. Second sentence follows."])

        let second = tracker.newRanges(
            in: "First sentence is here. Second sentence follows. Third sentence arrives now."
        )
        XCTAssertEqual(second.map(\.source), ["Third sentence arrives now."])
        XCTAssertEqual(second.first?.precedingContext, "First sentence is here. Second sentence follows.")

        let unchanged = tracker.newRanges(
            in: "First sentence is here. Second sentence follows. Third sentence arrives now."
        )
        XCTAssertTrue(unchanged.isEmpty)
    }

    func testEmissionTrackerReemitsOnlyARevisedSentence() {
        var tracker = StreamingEmissionTracker()
        _ = tracker.newRanges(
            in: "First sentence is here. Second sentence follows. Third sentence arrives now."
        )

        let revised = tracker.newRanges(
            in: "First sentence is here. Second sentence changed. Third sentence arrives now. Fourth one."
        )
        XCTAssertEqual(
            revised.map(\.source),
            ["Second sentence changed.", "Fourth one."]
        )
        XCTAssertEqual(
            tracker.emittedSegments,
            [
                "First sentence is here.",
                "Second sentence changed.",
                "Third sentence arrives now.",
                "Fourth one.",
            ]
        )

        // Emission continues after the revision instead of stopping for the
        // rest of the recording.
        let later = tracker.newRanges(
            in: "First sentence is here. Second sentence changed. Third sentence arrives now. Fourth one. Fifth sentence."
        )
        XCTAssertEqual(later.map(\.source), ["Fifth sentence."])
    }

    func testCommittedSentencePrefixHoldsSentencesNearTheSnapshotEdge() {
        XCTAssertEqual(
            StreamingTranscriptPolicy.committedSentencePrefix(
                of: "First sentence. Second sentence. Third sentence is unfinished",
                minimumTrailingWords: 3
            ),
            "First sentence. Second sentence."
        )
        XCTAssertEqual(
            StreamingTranscriptPolicy.committedSentencePrefix(
                of: "First sentence. Second sentence. It.",
                minimumTrailingWords: 3
            ),
            "First sentence."
        )
        XCTAssertEqual(
            StreamingTranscriptPolicy.committedSentencePrefix(
                of: "Only one sentence here.",
                minimumTrailingWords: 3
            ),
            ""
        )
        XCTAssertEqual(
            StreamingTranscriptPolicy.committedSentencePrefix(
                of: "Sections 1.10.32 and 1.10.33 were cited. Then more words",
                minimumTrailingWords: 3
            ),
            "Sections 1.10.32 and 1.10.33 were cited."
        )
    }

    func testShortFragmentsJoinTheFollowingSentence() async {
        let processor = RecordingTranscriptPolisher()
        let pipeline = StreamingTranscriptPolisher(
            isEnabled: true,
            model: .qwen3_0_6b,
            processor: processor
        )

        await pipeline.consumeStableSegment(
            "The librarian worked at the printing library in London."
        )
        await pipeline.consumeStableSegment("Bridge Brid St.")
        await pipeline.waitForQueuedWork()
        let callsBeforeMerge = await processor.streamingCalls
        XCTAssertEqual(callsBeforeMerge.count, 1)

        await pipeline.consumeStableSegment("Bride Library took a translation and scrambled it.")
        await pipeline.waitForQueuedWork()

        let calls = await processor.streamingCalls
        XCTAssertEqual(
            calls.map(\.transcript),
            [
                "The librarian worked at the printing library in London.",
                "Bridge Brid St. Bride Library took a translation and scrambled it.",
            ]
        )
        XCTAssertEqual(
            StreamingTranscriptPolicy.sentenceSegments(
                in: "At St. Bride we met. Then we left.",
                mergingSegmentsShorterThan: 4
            ),
            ["At St. Bride we met.", "Then we left."]
        )
    }

    func testTextFollowingCommittedTextExtractsTheTail() {
        let committed = "Lorem Ipsum is simply dummy text. It has survived not only many decades."
        XCTAssertEqual(
            StreamingTranscriptReconciler.textFollowing(
                committedText: committed,
                in: "vived not only many decades. But also the leap into electronic typesetting."
            ),
            "But also the leap into electronic typesetting."
        )
        XCTAssertNil(
            StreamingTranscriptReconciler.textFollowing(
                committedText: committed,
                in: "completely different words appear in this window."
            )
        )
        XCTAssertNil(
            StreamingTranscriptReconciler.textFollowing(
                committedText: committed,
                in: "not only many decades."
            )
        )
    }

    func testTerminalRangePolishesShortAndUnfinishedTextImmediately() async {
        let processor = RecordingTranscriptPolisher()
        let pipeline = StreamingTranscriptPolisher(
            isEnabled: true,
            model: .qwen3_0_6b,
            processor: processor
        )

        await pipeline.consumeStableSegment(
            StreamingStableRange(
                source: "Thank you",
                precedingContext: "That is everything I wanted to say.",
                followingContext: "",
                isTerminal: true
            )
        )
        await pipeline.waitForQueuedWork()

        let calls = await processor.streamingCalls
        XCTAssertEqual(calls.map(\.transcript), ["Thank you"])
        XCTAssertEqual(calls.first?.precedingContext, "That is everything I wanted to say.")
    }

    func testAnchorsRequireMatchingSentenceBoundaries() async {
        let processor = RecordingTranscriptPolisher()
        let pipeline = StreamingTranscriptPolisher(
            isEnabled: true,
            model: .qwen3_0_6b,
            processor: processor
        )

        await pipeline.consumeStableSegment("The book is a treatise.")
        await pipeline.consumeStableSegment("The first line comes from section one.")
        let final = "The book is a treatise on the theory of ethics. The first line comes from section one."
        let result = await pipeline.finalize(rawTranscript: final)

        // "The book is a treatise." was cut mid-sentence; its polished copy
        // must not be reused ahead of "on the theory of ethics".
        XCTAssertEqual(result.transcript, final)
        XCTAssertEqual(result.finalizationDiagnostics.strategy, .anchoredRanges)
        XCTAssertEqual(result.finalizationDiagnostics.reusedSegmentCount, 1)
        XCTAssertEqual(result.finalizationDiagnostics.reprocessedWordCount, 10)

        let calls = await processor.streamingCalls
        XCTAssertEqual(calls.last?.transcript, "The book is a treatise on the theory of ethics.")
    }

    func testRevisedSentenceEmittedLaterIsReusedInTranscriptOrder() async {
        let processor = RecordingTranscriptPolisher()
        let pipeline = StreamingTranscriptPolisher(
            isEnabled: true,
            model: .qwen3_0_6b,
            processor: processor
        )

        await pipeline.consumeStableSegment("The draft color is blue today.")
        await pipeline.consumeStableSegment("Last sentence remains exactly.")
        await pipeline.consumeStableSegment(
            StreamingStableRange(
                source: "The final color is green today.",
                precedingContext: "",
                followingContext: "Last sentence remains exactly."
            )
        )

        let final = "The final color is green today. Last sentence remains exactly."
        let result = await pipeline.finalize(rawTranscript: final)

        XCTAssertEqual(result.transcript, final)
        XCTAssertEqual(result.finalizationDiagnostics.reusedSegmentCount, 2)
        XCTAssertEqual(result.finalizationDiagnostics.reprocessedRangeCount, 0)
    }

    func testCompletedSegmentIsPolishedDuringRecordingAndTailAtRelease() async {
        let processor = RecordingTranscriptPolisher()
        let pipeline = StreamingTranscriptPolisher(
            isEnabled: true,
            model: .qwen3_0_6b,
            processor: processor
        )

        await pipeline.consumeStableSegment(
            "I think I think we should begin."
        )
        await pipeline.consumeStableSegment(
            "Then then we should continue"
        )

        let result = await pipeline.finalize(
            rawTranscript: "I think I think we should begin. Then then we should continue."
        )

        XCTAssertEqual(
            result.transcript,
            "I think we should begin. Then we should continue."
        )
        XCTAssertEqual(
            result.finalizationDiagnostics.strategy,
            .anchoredRanges
        )
        XCTAssertEqual(result.finalizationDiagnostics.reusedSegmentCount, 1)
        XCTAssertEqual(result.finalizationDiagnostics.reprocessedRangeCount, 1)

        let calls = await processor.streamingCalls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].transcript, "I think I think we should begin.")
        XCTAssertEqual(calls[1].transcript, "Then then we should continue.")
        XCTAssertEqual(calls[1].precedingContext, "I think I think we should begin.")
    }

    func testUnfinishedSegmentUsesFollowingWindowOnlyAsContext() async {
        let processor = RecordingTranscriptPolisher()
        let pipeline = StreamingTranscriptPolisher(
            isEnabled: true,
            model: .qwen3_0_6b,
            processor: processor
        )

        await pipeline.consumeStableSegment("We should deploy on Thursday sorry")
        await pipeline.waitForQueuedWork()
        let callsBeforeLookAhead = await processor.streamingCalls
        XCTAssertTrue(callsBeforeLookAhead.isEmpty)

        await pipeline.consumeStableSegment("I mean Friday after after the tests pass.")
        await pipeline.waitForQueuedWork()

        let calls = await processor.streamingCalls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].transcript, "We should deploy on Thursday sorry")
        XCTAssertEqual(
            calls[0].followingContext,
            "I mean Friday after after the tests pass."
        )
        XCTAssertFalse(calls[0].transcript.contains(calls[0].followingContext))
    }

    func testMultiSentenceCheckpointCreatesIndependentOwnershipSegments() async {
        let processor = RecordingTranscriptPolisher()
        let pipeline = StreamingTranscriptPolisher(
            isEnabled: true,
            model: .qwen3_0_6b,
            processor: processor
        )

        await pipeline.consumeStableSegment(
            "First first sentence is here. Second second sentence is here."
        )
        await pipeline.waitForQueuedWork()

        let calls = await processor.streamingCalls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.first?.transcript, "First first sentence is here.")
        XCTAssertEqual(calls.last?.transcript, "Second second sentence is here.")
        XCTAssertEqual(calls.first?.followingContext, "Second second sentence is here.")
    }

    func testFinalRevisionFallsBackToWholeTranscript() async {
        let processor = RecordingTranscriptPolisher()
        let pipeline = StreamingTranscriptPolisher(
            isEnabled: true,
            model: .qwen3_0_6b,
            processor: processor
        )

        await pipeline.consumeStableSegment("The first version is complete.")
        let final = "The revised version is complete. Keep this tail."
        let result = await pipeline.finalize(rawTranscript: final)

        XCTAssertEqual(result.transcript, final)
        XCTAssertEqual(
            result.finalizationDiagnostics.fullPassReason,
            .noSafeAnchors
        )
        let wholeTranscripts = await processor.wholeTranscripts
        XCTAssertEqual(wholeTranscripts, [final])
    }

    func testFinalRevisionReprocessesOnlyChangedMiddleRange() async {
        let processor = RecordingTranscriptPolisher()
        let pipeline = StreamingTranscriptPolisher(
            isEnabled: true,
            model: .qwen3_0_6b,
            processor: processor
        )

        await pipeline.consumeStableSegment("First sentence remains exactly.")
        await pipeline.consumeStableSegment("The draft color is blue.")
        await pipeline.consumeStableSegment("Last sentence remains exactly.")

        let final = "First sentence remains exactly. The final color is green. Last sentence remains exactly."
        let result = await pipeline.finalize(rawTranscript: final)

        XCTAssertEqual(result.transcript, final)
        XCTAssertEqual(
            result.finalizationDiagnostics.strategy,
            .anchoredRanges
        )
        XCTAssertEqual(result.finalizationDiagnostics.completedSegmentCount, 3)
        XCTAssertEqual(result.finalizationDiagnostics.reusedSegmentCount, 2)
        XCTAssertEqual(result.finalizationDiagnostics.reusedWordCount, 8)
        XCTAssertEqual(result.finalizationDiagnostics.reprocessedWordCount, 5)
        XCTAssertEqual(result.finalizationDiagnostics.reprocessedRangeCount, 1)

        let calls = await processor.streamingCalls
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(calls.last?.transcript, "The final color is green.")
        XCTAssertEqual(
            calls.last?.precedingContext,
            "First sentence remains exactly."
        )
        XCTAssertEqual(
            calls.last?.followingContext,
            "Last sentence remains exactly."
        )
        let wholeTranscripts = await processor.wholeTranscripts
        XCTAssertTrue(wholeTranscripts.isEmpty)
    }

    func testContextLeakageDetectionRejectsCopiedHalos() {
        let previous = "This sentence belongs to the previous stable window."
        let following = "This sentence belongs to the following stable window."

        XCTAssertTrue(
            TranscriptPolishPolicy.leaksStreamingContext(
                previous + " Polish this target.",
                precedingContext: previous,
                followingContext: following
            )
        )
        XCTAssertTrue(
            TranscriptPolishPolicy.leaksStreamingContext(
                "Polish this target. " + following,
                precedingContext: previous,
                followingContext: following
            )
        )
        XCTAssertFalse(
            TranscriptPolishPolicy.leaksStreamingContext(
                "Polish this target.",
                precedingContext: previous,
                followingContext: following
            )
        )
    }

    func testStreamingEditRejectsPromptScaffoldingAndDuplicatedOwnership() {
        let source = "The point of using Lorem Ipsum is that it has a normal distribution of letters."

        XCTAssertFalse(
            TranscriptPolishPolicy.isStreamingEditAcceptable(
                "Preceding context: do not return. Target segment: \(source)",
                for: source
            )
        )
        XCTAssertFalse(
            TranscriptPolishPolicy.isStreamingEditAcceptable(
                source + " " + source,
                for: source
            )
        )
        XCTAssertTrue(
            TranscriptPolishPolicy.isStreamingEditAcceptable(
                "The point of using Lorem Ipsum is that it has a normal distribution of letters.",
                for: "The point of using Lorem Ipsum is that it has a a normal distribution of letters."
            )
        )
    }

    func testSentenceSegmentsSplitAtStrongBoundaries() {
        XCTAssertEqual(
            StreamingTranscriptPolicy.sentenceSegments(
                in: "First sentence. Second sentence! Last fragment"
            ),
            ["First sentence.", "Second sentence!", "Last fragment"]
        )
    }

    func testLiveAudioAccumulatorPreservesContinuousMono16kSamples() throws {
        var accumulator = LiveAudioAccumulator()
        try accumulator.append(
            LiveAudioChunk(mono16kSamples: [0.1, 0.2, 0.3])
        )
        try accumulator.append(
            LiveAudioChunk(mono16kSamples: [0.4, 0.5])
        )

        XCTAssertEqual(accumulator.duration, 5.0 / 16_000.0, accuracy: 0.000_001)
        XCTAssertEqual(
            try accumulator.mono16kSamples(),
            [0.1, 0.2, 0.3, 0.4, 0.5]
        )
    }
}

private actor RecordingTranscriptPolisher: TranscriptPolishing {
    struct StreamingCall: Sendable {
        let transcript: String
        let precedingContext: String
        let followingContext: String
    }

    private(set) var streamingCalls: [StreamingCall] = []
    private(set) var wholeTranscripts: [String] = []

    func polish(
        _ transcript: String,
        using model: PostProcessingModel
    ) async throws -> String {
        wholeTranscripts.append(transcript)
        return transcript
    }

    func polishStreamingSegment(
        _ transcript: String,
        precedingContext: String,
        followingContext: String,
        using model: PostProcessingModel
    ) async throws -> String {
        streamingCalls.append(
            StreamingCall(
                transcript: transcript,
                precedingContext: precedingContext,
                followingContext: followingContext
            )
        )
        return transcript
            .replacingOccurrences(of: "I think I think", with: "I think")
            .replacingOccurrences(of: "Then then", with: "Then")
            .replacingOccurrences(of: "after after", with: "after")
    }
}
