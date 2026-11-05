import AppKit
import Combine
import Foundation

/// State of the "Transcribe audio" screen. It lives as long as the app, so a
/// long file keeps running while the user is back on the Welcome screen or the
/// window is closed.
@MainActor
final class FileTranscriptionViewModel: ObservableObject {
    enum Stage: Int, Comparable {
        case decoding
        case transcribing
        case polishing

        static func < (lhs: Stage, rhs: Stage) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var title: String {
            switch self {
            case .decoding:
                return "Reading audio…"
            case .transcribing:
                return "Transcribing…"
            case .polishing:
                return "Cleaning up…"
            }
        }
    }

    enum Phase: Equatable {
        case empty
        case ready
        case running(Stage, progress: Double)
        case finished
        case failed(String)
    }

    @Published private(set) var phase: Phase = .empty
    @Published private(set) var file: AudioFileSummary?
    @Published private(set) var transcript = ""
    @Published private(set) var isInspectingFile = false
    @Published private(set) var selectionError: String?
    @Published private(set) var didCopyTranscript = false

    private let transcriber: any AudioFileTranscribing
    private let inspect: @Sendable (URL) async throws -> AudioFileSummary
    private let preferences: AppPreferences
    private let readiness: PostProcessingReadiness
    private let usageStatistics: UsageStatistics
    private let pasteboard: NSPasteboard

    private var runTask: Task<Void, Never>?
    private var runID: UUID?
    private var runUsesPostProcessing = false
    private var selectionID: UUID?
    private var copyResetTask: Task<Void, Never>?

    init(
        transcriber: any AudioFileTranscribing,
        inspect: @escaping @Sendable (URL) async throws -> AudioFileSummary = { url in
            try await AudioFileDecoder.summary(of: url)
        },
        preferences: AppPreferences,
        readiness: PostProcessingReadiness,
        usageStatistics: UsageStatistics,
        pasteboard: NSPasteboard = .general
    ) {
        self.transcriber = transcriber
        self.inspect = inspect
        self.preferences = preferences
        self.readiness = readiness
        self.usageStatistics = usageStatistics
        self.pasteboard = pasteboard
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var canRun: Bool {
        file != nil && !isRunning && !isInspectingFile
    }

    /// Counts the way a reader would, so "2,000" is one word. The usage total
    /// splits on punctuation as well and would call it two.
    var wordCount: Int {
        transcript.split(whereSeparator: \.isWhitespace).count
    }

    /// Reads the file's details so a file macOS cannot decode is rejected when
    /// it is dropped, not after the user has pressed Transcribe. A rejected
    /// file leaves the current file and transcript untouched.
    func select(_ url: URL) {
        guard !isRunning else { return }

        let selectionID = UUID()
        self.selectionID = selectionID
        isInspectingFile = true
        selectionError = nil

        let inspect = self.inspect
        Task { [weak self] in
            do {
                let summary = try await inspect(url)
                guard let self, self.selectionID == selectionID else { return }
                self.isInspectingFile = false
                self.file = summary
                self.transcript = ""
                self.didCopyTranscript = false
                self.phase = .ready
            } catch {
                guard let self, self.selectionID == selectionID else { return }
                self.isInspectingFile = false
                self.selectionError = Self.message(for: error)
            }
        }
    }

    func run() {
        guard let file, canRun else { return }

        let runID = UUID()
        self.runID = runID
        let postProcessingEnabled = preferences.postProcessingEnabled
        runUsesPostProcessing = postProcessingEnabled
        transcript = ""
        selectionError = nil
        didCopyTranscript = false
        phase = .running(.decoding, progress: 0)

        // Keeps a long file running at full speed with the window hidden, and
        // keeps the Mac from going to sleep halfway through it.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated,
            reason: "Transcribing an audio file"
        )
        let transcriber = self.transcriber
        runTask = Task { [weak self] in
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                let result = try await transcriber.transcribe(
                    file.url,
                    postProcessingEnabled: postProcessingEnabled
                ) { update in
                    Task { @MainActor [weak self] in
                        self?.apply(update, runID: runID)
                    }
                }
                self?.finish(result, runID: runID)
            } catch is CancellationError {
                // cancel() and skipCleanup() have already moved the screen on.
            } catch {
                self?.fail(error, runID: runID)
            }
        }
    }

    func cancel() {
        guard isRunning else { return }
        endRun()
        transcript = ""
        phase = .ready
    }

    /// Stops the language model and keeps Parakeet's text. Cleanup of a long
    /// file can take minutes, and the draft is already complete by then.
    func skipCleanup() {
        guard case .running(.polishing, _) = phase, !transcript.isEmpty else { return }
        endRun()
        usageStatistics.record(transcript: transcript, duration: file?.duration ?? 0)
        phase = .finished
    }

    func startOver() {
        endRun()
        selectionID = nil
        isInspectingFile = false
        selectionError = nil
        file = nil
        transcript = ""
        didCopyTranscript = false
        phase = .empty
    }

    func copyTranscript() {
        guard phase == .finished, !transcript.isEmpty else { return }
        pasteboard.clearContents()
        guard pasteboard.setString(transcript, forType: .string) else {
            selectionError = LocalTranscriberError.clipboardWriteFailed.errorDescription
            return
        }

        didCopyTranscript = true
        copyResetTask?.cancel()
        copyResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.didCopyTranscript = false
        }
    }

    private func apply(_ update: AudioFileTranscriptionUpdate, runID: UUID) {
        guard runID == self.runID else { return }
        switch update {
        case let .decoding(progress):
            advance(to: .decoding, stageProgress: progress)
        case let .transcribing(progress):
            advance(to: .transcribing, stageProgress: progress)
        case let .draft(text):
            transcript = text
        case let .polishing(progress):
            advance(to: .polishing, stageProgress: progress)
        }
    }

    /// Updates hop to the main actor one by one and may arrive slightly out of
    /// order, so the bar only ever moves forward. Within a stage it moves in
    /// whole percent steps, which is all the screen shows.
    private func advance(to stage: Stage, stageProgress: Double) {
        guard case let .running(currentStage, currentProgress) = phase,
              stage >= currentStage else { return }
        let range = Self.progressRange(for: stage, postProcessing: runUsesPostProcessing)
        let progress = range.lowerBound
            + (range.upperBound - range.lowerBound) * min(1, max(0, stageProgress))
        guard stage > currentStage
            || (progress * 100).rounded(.down) > (currentProgress * 100).rounded(.down) else {
            return
        }
        phase = .running(stage, progress: max(progress, currentProgress))
    }

    /// The share of the bar each stage gets. The language model is by far the
    /// slowest stage when it runs. Its range stops short of the end because the
    /// final reconciliation of a long transcript takes a few more seconds, and
    /// a bar resting at 100% would look stuck.
    private static func progressRange(
        for stage: Stage,
        postProcessing: Bool
    ) -> ClosedRange<Double> {
        switch (stage, postProcessing) {
        case (.decoding, true):
            return 0...0.02
        case (.transcribing, true):
            return 0.02...0.15
        case (.polishing, _):
            return 0.15...0.98
        case (.decoding, false):
            return 0...0.1
        case (.transcribing, false):
            return 0.1...1
        }
    }

    private func finish(_ result: AudioFileTranscript, runID: UUID) {
        guard runID == self.runID else { return }
        transcript = result.transcript
        usageStatistics.record(transcript: result.transcript, duration: result.duration)
        endRun()
        phase = .finished
    }

    private func fail(_ error: Error, runID: UUID) {
        guard runID == self.runID else { return }
        WordmateLog.fileTranscription.error(
            "File transcription failed: \(error.localizedDescription, privacy: .public)"
        )
        endRun()
        transcript = ""
        phase = .failed(Self.message(for: error))
    }

    private func endRun() {
        runTask?.cancel()
        runTask = nil
        runID = nil
        // The language model reloads itself on demand. Turning post-processing
        // off during a run must still leave it unloaded once the run is over.
        if runUsesPostProcessing, !preferences.postProcessingEnabled {
            readiness.unload()
        }
        runUsesPostProcessing = false
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
