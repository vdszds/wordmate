import XCTest
@testable import LocalTranscriber

final class StreamingTranscriptPolisherTests: XCTestCase {
    func testReconcilerReturnsOnlyUnprocessedFinalWords() {
        let suffix = StreamingTranscriptReconciler.unprocessedSuffix(
            in: "Hello, world. This is the final sentence.",
            afterProcessedPrefix: "hello WORLD"
        )

        XCTAssertEqual(suffix, "This is the final sentence.")
    }

    func testReconcilerRejectsAChangedProcessedPrefix() {
        XCTAssertNil(
            StreamingTranscriptReconciler.unprocessedSuffix(
                in: "Hello different world. This is the tail.",
                afterProcessedPrefix: "Hello quiet world."
            )
        )
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
        let callsBeforeLookAhead = await processor.streamingCalls
        XCTAssertTrue(callsBeforeLookAhead.isEmpty)

        await pipeline.consumeStableSegment("I mean Friday after after the tests pass.")

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
            "First first sentence. Second second sentence."
        )

        let calls = await processor.streamingCalls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].transcript, "First first sentence.")
        XCTAssertEqual(calls[1].transcript, "Second second sentence.")
        XCTAssertEqual(calls[0].followingContext, "Second second sentence.")
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

    func testStablePrefixAlwaysHoldsTheNewestSentence() {
        XCTAssertEqual(
            StreamingTranscriptPolicy.stablePrefix(
                of: "First sentence. Second sentence. Third sentence is unfinished"
            ),
            "First sentence."
        )
        XCTAssertEqual(
            StreamingTranscriptPolicy.stablePrefix(
                of: "First sentence. Second sentence."
            ),
            "First sentence."
        )
        XCTAssertEqual(
            StreamingTranscriptPolicy.stablePrefix(of: "Only one sentence."),
            ""
        )
    }

    func testCompleteSentencePrefixUsesNewestConfirmedBoundary() {
        XCTAssertEqual(
            StreamingTranscriptPolicy.completeSentencePrefix(
                of: "First sentence. Second sentence. Third sentence is unfinished"
            ),
            "First sentence. Second sentence."
        )
        XCTAssertEqual(
            StreamingTranscriptPolicy.completeSentencePrefix(
                of: "Only an unfinished sentence"
            ),
            ""
        )
        XCTAssertEqual(
            StreamingTranscriptPolicy.sentenceSegments(
                in: "First sentence. Second sentence! Last fragment"
            ),
            ["First sentence.", "Second sentence!", "Last fragment"]
        )
    }

    func testConfirmedPrefixUsesConsecutiveSnapshotsAndHoldsBackWords() {
        let previous = "Alpha beta gamma delta epsilon zeta eta theta iota kappa."
        let current = previous + " Lambda mu nu."

        XCTAssertEqual(
            StreamingTranscriptReconciler.confirmedPrefix(
                in: current,
                against: previous,
                holdingBack: 3
            ),
            "Alpha beta gamma delta epsilon zeta eta"
        )
        XCTAssertEqual(
            StreamingTranscriptReconciler.confirmedPrefix(
                in: "Alpha beta changed delta epsilon zeta eta theta.",
                against: previous,
                holdingBack: 3
            ),
            ""
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
