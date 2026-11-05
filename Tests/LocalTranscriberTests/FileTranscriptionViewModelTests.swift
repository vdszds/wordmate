import AppKit
import XCTest
@testable import LocalTranscriber

@MainActor
final class FileTranscriptionViewModelTests: XCTestCase {
    private let audioURL = URL(fileURLWithPath: "/tmp/memo.m4a")
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaultsSuiteName = "FileTranscriptionViewModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    func testFileMovesToReadyAndRunProducesTranscriptAndUsage() async throws {
        let transcriber = FakeTranscriber()
        let statistics = UsageStatistics(defaults: defaults)
        let viewModel = makeViewModel(transcriber: transcriber, statistics: statistics)
        XCTAssertFalse(viewModel.canRun)

        await select(audioURL, on: viewModel)
        XCTAssertEqual(viewModel.phase, .ready)
        XCTAssertEqual(viewModel.file?.name, "memo.m4a")
        XCTAssertTrue(viewModel.canRun)

        viewModel.run()
        XCTAssertTrue(viewModel.isRunning)
        await transcriber.waitUntilStarted()
        await transcriber.complete(with: .success(AudioFileTranscript(transcript: "Hello there.", duration: 90)))
        await waitUntil { viewModel.phase == .finished }

        XCTAssertEqual(viewModel.transcript, "Hello there.")
        XCTAssertEqual(viewModel.wordCount, 2)
        XCTAssertEqual(statistics.totalWords, 2)
        XCTAssertEqual(statistics.totalRecordingDuration, 90)
    }

    func testWordCountTreatsAFormattedNumberAsOneWord() async throws {
        let transcriber = FakeTranscriber()
        let viewModel = makeViewModel(transcriber: transcriber)

        await select(audioURL, on: viewModel)
        viewModel.run()
        await transcriber.waitUntilStarted()
        await transcriber.complete(with: .success(AudioFileTranscript(transcript: "We sold 2,000 units.", duration: 5)))
        await waitUntil { viewModel.phase == .finished }

        XCTAssertEqual(viewModel.wordCount, 4)
    }

    func testRunUsesCurrentPostProcessingPreference() async throws {
        let transcriber = FakeTranscriber()
        let preferences = AppPreferences(defaults: defaults)
        preferences.postProcessingEnabled = true
        let viewModel = makeViewModel(transcriber: transcriber, preferences: preferences)

        await select(audioURL, on: viewModel)
        viewModel.run()
        await transcriber.waitUntilStarted()

        let usedPostProcessing = await transcriber.postProcessingEnabled
        XCTAssertEqual(usedPostProcessing, true)
        viewModel.cancel()
        await transcriber.complete(with: .failure(CancellationError()))
    }

    func testEnteringCleanupShowsItsStageEvenWithinTheSamePercent() async throws {
        let transcriber = FakeTranscriber()
        let preferences = AppPreferences(defaults: defaults)
        preferences.postProcessingEnabled = true
        let viewModel = makeViewModel(transcriber: transcriber, preferences: preferences)
        await select(audioURL, on: viewModel)
        viewModel.run()
        await transcriber.waitUntilStarted()

        await transcriber.send(.transcribing(1))
        await waitUntil {
            if case .running(.transcribing, _) = viewModel.phase { return true }
            return false
        }
        await transcriber.send(.polishing(0))
        await waitUntil {
            if case .running(.polishing, _) = viewModel.phase { return true }
            return false
        }

        viewModel.cancel()
        await transcriber.complete(with: .failure(CancellationError()))
    }

    func testProgressOnlyMovesForwardAcrossStages() async throws {
        let transcriber = FakeTranscriber()
        let viewModel = makeViewModel(transcriber: transcriber)
        await select(audioURL, on: viewModel)
        viewModel.run()
        await transcriber.waitUntilStarted()

        await transcriber.send(.transcribing(0.5))
        await waitUntil {
            if case .running(.transcribing, _) = viewModel.phase { return true }
            return false
        }
        guard case let .running(_, progress) = viewModel.phase else {
            return XCTFail("Expected a running phase")
        }

        await transcriber.send(.decoding(0.1))
        await settle()

        guard case let .running(stage, laterProgress) = viewModel.phase else {
            return XCTFail("Expected a running phase")
        }
        XCTAssertEqual(stage, .transcribing)
        XCTAssertEqual(laterProgress, progress)
        viewModel.cancel()
        await transcriber.complete(with: .failure(CancellationError()))
    }

    func testCancelReturnsToReadyAndIgnoresLateResult() async throws {
        let transcriber = FakeTranscriber()
        let statistics = UsageStatistics(defaults: defaults)
        let viewModel = makeViewModel(transcriber: transcriber, statistics: statistics)
        await select(audioURL, on: viewModel)
        viewModel.run()
        await transcriber.waitUntilStarted()

        viewModel.cancel()
        XCTAssertEqual(viewModel.phase, .ready)
        XCTAssertEqual(viewModel.file?.name, "memo.m4a")

        await transcriber.complete(with: .success(AudioFileTranscript(transcript: "Too late.", duration: 5)))
        await settle()

        XCTAssertEqual(viewModel.phase, .ready)
        XCTAssertEqual(viewModel.transcript, "")
        XCTAssertEqual(statistics.totalWords, 0)
    }

    func testSkipCleanupKeepsDraftAsTheResult() async throws {
        let transcriber = FakeTranscriber()
        let statistics = UsageStatistics(defaults: defaults)
        let viewModel = makeViewModel(transcriber: transcriber, statistics: statistics)
        await select(audioURL, on: viewModel)
        viewModel.run()
        await transcriber.waitUntilStarted()

        await transcriber.send(.draft("A raw draft"))
        await transcriber.send(.polishing(0.5))
        await waitUntil {
            if case .running(.polishing, _) = viewModel.phase { return !viewModel.transcript.isEmpty }
            return false
        }

        viewModel.skipCleanup()

        XCTAssertEqual(viewModel.phase, .finished)
        XCTAssertEqual(viewModel.transcript, "A raw draft")
        XCTAssertEqual(statistics.totalWords, 3)

        // The cancelled run must not overwrite or double count the kept draft.
        await transcriber.complete(with: .success(AudioFileTranscript(transcript: "Polished.", duration: 5)))
        await settle()
        XCTAssertEqual(viewModel.transcript, "A raw draft")
        XCTAssertEqual(statistics.totalWords, 3)
    }

    func testFailureCanBeRetriedWithTheSameFile() async throws {
        let transcriber = FakeTranscriber()
        let viewModel = makeViewModel(transcriber: transcriber)
        await select(audioURL, on: viewModel)
        viewModel.run()
        await transcriber.waitUntilStarted()

        await transcriber.complete(with: .failure(LocalTranscriberError.noSpeechDetected))
        await waitUntil {
            if case .failed = viewModel.phase { return true }
            return false
        }
        XCTAssertEqual(viewModel.phase, .failed("No speech was detected."))
        XCTAssertEqual(viewModel.file?.name, "memo.m4a")

        await transcriber.reset()
        viewModel.run()
        await transcriber.waitUntilStarted()
        await transcriber.complete(with: .success(AudioFileTranscript(transcript: "Second try.", duration: 5)))
        await waitUntil { viewModel.phase == .finished }

        XCTAssertEqual(viewModel.transcript, "Second try.")
    }

    func testRejectedFileLeavesFinishedResultInPlace() async throws {
        let transcriber = FakeTranscriber()
        let badURL = URL(fileURLWithPath: "/tmp/notes.txt")
        let viewModel = makeViewModel(transcriber: transcriber) { url in
            if url == badURL {
                throw LocalTranscriberError.unsupportedAudioFile("notes.txt")
            }
            return Self.summary(for: url)
        }
        await select(audioURL, on: viewModel)
        viewModel.run()
        await transcriber.waitUntilStarted()
        await transcriber.complete(with: .success(AudioFileTranscript(transcript: "Keep me.", duration: 5)))
        await waitUntil { viewModel.phase == .finished }

        await select(badURL, on: viewModel)

        XCTAssertEqual(viewModel.phase, .finished)
        XCTAssertEqual(viewModel.transcript, "Keep me.")
        XCTAssertEqual(viewModel.file?.name, "memo.m4a")
        XCTAssertEqual(
            viewModel.selectionError,
            LocalTranscriberError.unsupportedAudioFile("notes.txt").errorDescription
        )
    }

    func testNewFileReplacesFinishedResult() async throws {
        let transcriber = FakeTranscriber()
        let viewModel = makeViewModel(transcriber: transcriber)
        await select(audioURL, on: viewModel)
        viewModel.run()
        await transcriber.waitUntilStarted()
        await transcriber.complete(with: .success(AudioFileTranscript(transcript: "Old.", duration: 5)))
        await waitUntil { viewModel.phase == .finished }

        await select(URL(fileURLWithPath: "/tmp/next.mp3"), on: viewModel)

        XCTAssertEqual(viewModel.phase, .ready)
        XCTAssertEqual(viewModel.transcript, "")
        XCTAssertEqual(viewModel.file?.name, "next.mp3")
    }

    func testDropWhileRunningIsIgnored() async throws {
        let transcriber = FakeTranscriber()
        let viewModel = makeViewModel(transcriber: transcriber)
        await select(audioURL, on: viewModel)
        viewModel.run()
        await transcriber.waitUntilStarted()

        viewModel.select(URL(fileURLWithPath: "/tmp/other.mp3"))
        await settle()

        XCTAssertEqual(viewModel.file?.name, "memo.m4a")
        XCTAssertTrue(viewModel.isRunning)
        viewModel.cancel()
        await transcriber.complete(with: .failure(CancellationError()))
    }

    func testStartOverClearsEverything() async throws {
        let transcriber = FakeTranscriber()
        let viewModel = makeViewModel(transcriber: transcriber)
        await select(audioURL, on: viewModel)
        viewModel.run()
        await transcriber.waitUntilStarted()
        await transcriber.complete(with: .success(AudioFileTranscript(transcript: "Done.", duration: 5)))
        await waitUntil { viewModel.phase == .finished }

        viewModel.startOver()

        XCTAssertEqual(viewModel.phase, .empty)
        XCTAssertNil(viewModel.file)
        XCTAssertEqual(viewModel.transcript, "")
        XCTAssertFalse(viewModel.canRun)
    }

    func testCopyPlacesFinishedTranscriptOnPasteboard() async throws {
        let transcriber = FakeTranscriber()
        let pasteboard = NSPasteboard(name: .init("FileTranscriptionViewModelTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let viewModel = makeViewModel(transcriber: transcriber, pasteboard: pasteboard)
        await select(audioURL, on: viewModel)

        viewModel.copyTranscript()
        XCTAssertFalse(viewModel.didCopyTranscript)

        viewModel.run()
        await transcriber.waitUntilStarted()
        await transcriber.complete(with: .success(AudioFileTranscript(transcript: "Copy me.", duration: 5)))
        await waitUntil { viewModel.phase == .finished }

        viewModel.copyTranscript()

        XCTAssertTrue(viewModel.didCopyTranscript)
        XCTAssertEqual(pasteboard.string(forType: .string), "Copy me.")
    }

    func testDurationFormatting() {
        XCTAssertEqual(FileTranscriptionView.formattedDuration(0.2), "0:01")
        XCTAssertEqual(FileTranscriptionView.formattedDuration(71.3), "1:11")
        XCTAssertEqual(FileTranscriptionView.formattedDuration(3_725), "1:02:05")
    }

    private func makeViewModel(
        transcriber: FakeTranscriber,
        preferences: AppPreferences? = nil,
        statistics: UsageStatistics? = nil,
        pasteboard: NSPasteboard = NSPasteboard(name: .init("FileTranscriptionViewModelTests.unused")),
        inspect: (@Sendable (URL) async throws -> AudioFileSummary)? = nil
    ) -> FileTranscriptionViewModel {
        FileTranscriptionViewModel(
            transcriber: transcriber,
            inspect: inspect ?? { Self.summary(for: $0) },
            preferences: preferences ?? AppPreferences(defaults: defaults),
            readiness: PostProcessingReadiness(
                processor: TranscriptPostProcessor(),
                model: .qwen3_0_6b
            ),
            usageStatistics: statistics ?? UsageStatistics(defaults: defaults),
            pasteboard: pasteboard
        )
    }

    private nonisolated static func summary(for url: URL) -> AudioFileSummary {
        AudioFileSummary(
            url: url,
            name: url.lastPathComponent,
            format: url.pathExtension.uppercased(),
            duration: 90,
            byteCount: 1_000,
            hasVideo: false
        )
    }

    private func select(_ url: URL, on viewModel: FileTranscriptionViewModel) async {
        viewModel.select(url)
        await waitUntil { !viewModel.isInspectingFile }
    }

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition was not met in time", file: file, line: line)
    }

    /// Long enough for already-scheduled main-actor hops to have run.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(60))
    }
}

/// Runs until a test completes it, ignoring cancellation the way a Parakeet
/// chunk or a language-model call already in flight does.
private actor FakeTranscriber: AudioFileTranscribing {
    private(set) var postProcessingEnabled: Bool?
    private var onUpdate: (@Sendable (AudioFileTranscriptionUpdate) -> Void)?
    private var completion: CheckedContinuation<AudioFileTranscript, Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func transcribe(
        _ url: URL,
        postProcessingEnabled: Bool,
        onUpdate: @escaping @Sendable (AudioFileTranscriptionUpdate) -> Void
    ) async throws -> AudioFileTranscript {
        self.postProcessingEnabled = postProcessingEnabled
        self.onUpdate = onUpdate
        return try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
        }
    }

    func waitUntilStarted() async {
        guard completion == nil else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func send(_ update: AudioFileTranscriptionUpdate) {
        onUpdate?(update)
    }

    func complete(with result: Result<AudioFileTranscript, Error>) {
        completion?.resume(with: result)
        completion = nil
    }

    func reset() {
        completion = nil
        onUpdate = nil
    }
}
