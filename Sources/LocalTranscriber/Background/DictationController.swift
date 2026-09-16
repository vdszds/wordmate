import AppKit
import Combine
import CoreGraphics
import Foundation
import os

@MainActor
final class DictationController: ObservableObject {
    enum RecordingMode: Equatable {
        case gesturePending
        case pushToTalk
        case continuous
    }

    enum Phase: Equatable {
        case idle
        case recording(RecordingMode)
        case processing(RecordingMode)
        case success(TextInsertionResult)
        case failure(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var audioLevel = 0.0

    /// False from the moment a recording starts until the microphone delivers
    /// its first buffer that is not pure digital silence. A real microphone
    /// always carries noise, so this is the earliest honest moment; a
    /// Bluetooth headset delivers exact zeros while it switches profiles and
    /// the pill must not look ready before then.
    @Published private(set) var isMicrophoneLive = false

    /// Called when a push-to-talk hold ended because the Fn release event was
    /// lost, so the key monitor can forget the stale press.
    var onFnHoldLost: (() -> Void)?

    private let preferences: AppPreferences
    private let modelRunner: ModelRunner
    private let transcriptPostProcessor: TranscriptPostProcessor
    private let postProcessingReadiness: PostProcessingReadiness
    private let usageStatistics: UsageStatistics
    private let recorder = MicrophoneRecorder()
    private let textInserter = FocusedTextInserter()
    private let doubleTapInterval: TimeInterval = 0.42
    private let quickTapMaximumDuration: TimeInterval = 0.28
    private let pushToTalkRevealDelay: TimeInterval = 0.16
    private let failureDisplayDuration: Duration = .milliseconds(2_500)
    private static let transcriptionEngine = EngineChoice.parakeet
    private static let postProcessingModel = PostProcessingModel.qwen3_0_6b

    private var meterTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var pendingPushToTalkAcceptance: Task<Void, Never>?
    private var pushToTalkRevealTask: Task<Void, Never>?
    private var targetPID: pid_t?
    private var fnPressedAt: TimeInterval?
    private var lastQuickFnReleaseAt: TimeInterval?
    private var fnHoldReconciler = FnHoldReconciler()
    private var operationID: UUID?
    private var recordingID = UUID()
    private var liveAudioCapture: LiveAudioCapture?
    private var livePolisher: StreamingTranscriptPolisher?
    private var livePipelineTask: Task<LiveDictationResult, Error>?

    init(
        preferences: AppPreferences,
        modelRunner: ModelRunner,
        transcriptPostProcessor: TranscriptPostProcessor,
        postProcessingReadiness: PostProcessingReadiness,
        usageStatistics: UsageStatistics
    ) {
        self.preferences = preferences
        self.modelRunner = modelRunner
        self.transcriptPostProcessor = transcriptPostProcessor
        self.postProcessingReadiness = postProcessingReadiness
        self.usageStatistics = usageStatistics
    }

    /// Loads Parakeet, then Qwen. Loading them one after the other keeps a
    /// cold start responsive on machines with less memory and fewer cores.
    func warmModels() {
        MicrophoneRecorder.prewarmCaptureStack()
        let modelRunner = self.modelRunner
        let transcriptionWarmup: Task<Void, Never> = Task {
            _ = try? await modelRunner.prepare(Self.transcriptionEngine)
        }
        guard preferences.postProcessingEnabled else { return }
        let readiness = postProcessingReadiness
        Task {
            await readiness.prepare(after: transcriptionWarmup)
        }
    }

    func handleFnTransition(_ transition: FnKeyTransition) {
        switch transition {
        case let .pressed(timestamp):
            handleFnPress(at: timestamp)
        case let .released(timestamp):
            handleFnRelease(at: timestamp)
        }
    }

    func startContinuousRecording() {
        clearFailureIfNeeded()
        guard phase == .idle else { return }
        beginRecording(mode: .continuous)
    }

    func reject() {
        guard case .recording = phase else { return }
        WordmateLog.dictation.info("Recording \(self.recordingID, privacy: .public) discarded")
        cancelInteractionTasks()
        stopMetering()
        recorder.abandon()
        cancelLivePipeline()
        isMicrophoneLive = false
        targetPID = nil
        phase = .idle
    }

    func discardContinuousRecording() {
        guard phase == .recording(.continuous) else { return }
        reject()
    }

    func accept() async {
        guard case let .recording(recordingMode) = phase else { return }
        let processingMode: RecordingMode = recordingMode == .continuous
            ? .continuous
            : .pushToTalk
        targetPID = frontmostExternalApplicationPID() ?? targetPID
        cancelInteractionTasks()
        stopMetering()
        phase = .processing(processingMode)

        let currentOperationID = UUID()
        operationID = currentOperationID
        let recordingID = self.recordingID
        WordmateLog.dictation.info("Recording \(recordingID, privacy: .public) accepted; stopping microphone")

        let recording: AudioRecording
        do {
            recording = try await recorder.stop()
            isMicrophoneLive = false
            liveAudioCapture?.finish()
            liveAudioCapture = nil
        } catch {
            cancelLivePipeline()
            operationID = nil
            showFailure(error)
            return
        }
        guard operationID == currentOperationID else {
            try? FileManager.default.removeItem(at: recording.fileURL)
            return
        }

        defer {
            try? FileManager.default.removeItem(at: recording.fileURL)
        }

        do {
            guard recording.duration >= 0.1 else {
                throw LocalTranscriberError.recordingTooShort
            }
            if !recording.isComplete {
                WordmateLog.dictation.error(
                    "Recording \(recordingID, privacy: .public): microphone did not stop in time; using live audio only"
                )
            }

            var result: LiveDictationResult?
            if let livePipelineTask {
                do {
                    let liveResult = try await livePipelineTask.value
                    if !liveResult.rawTranscript.isEmpty {
                        result = liveResult
                    }
                } catch {
                    // The complete CAF recording remains the source of truth.
                    // Any streaming failure transparently falls back to the
                    // original batch path instead of losing the dictation.
                    WordmateLog.dictation.error(
                        "Live pipeline failed for \(recordingID, privacy: .public): \(error.localizedDescription, privacy: .public); using batch path"
                    )
                }
                self.livePipelineTask = nil
                self.livePolisher = nil
                guard operationID == currentOperationID else { return }
            }

            if result == nil {
                guard recording.isComplete else {
                    throw LocalTranscriberError.microphoneUnavailable(
                        "The microphone did not stop in time and the recording could not be finalized. Try again."
                    )
                }
                result = try await processBatchRecording(recording)
            }
            guard operationID == currentOperationID,
                  let result else { return }

            guard !result.rawTranscript.isEmpty else {
                throw LocalTranscriberError.noSpeechDetected
            }

            let insertionResult = try await textInserter.insert(
                result.transcript,
                targetPID: targetPID
            )
            guard operationID == currentOperationID else { return }

            usageStatistics.record(
                transcript: result.transcript,
                duration: recording.duration
            )
            WordmateLog.dictation.info(
                "Recording \(recordingID, privacy: .public) finished: \(recording.duration, privacy: .public) s, \(insertionResult.message, privacy: .public)"
            )

            operationID = nil
            targetPID = nil
            phase = .success(insertionResult)
            scheduleReset(after: .milliseconds(250))
        } catch {
            guard operationID == currentOperationID else { return }
            livePipelineTask = nil
            livePolisher = nil
            operationID = nil
            targetPID = nil
            showFailure(error)
        }
    }

    func stop() {
        resetTask?.cancel()
        stopMetering()
        cancelInteractionTasks()
        resetTask = nil
        operationID = nil
        cancelLivePipeline()

        if case .recording = phase {
            recorder.abandon()
        }
        isMicrophoneLive = false
        targetPID = nil
        phase = .idle
    }

    private func handleFnPress(at timestamp: TimeInterval) {
        clearFailureIfNeeded()

        switch phase {
        case .idle:
            fnPressedAt = timestamp
            lastQuickFnReleaseAt = nil
            fnHoldReconciler.reset()
            beginRecording(mode: .gesturePending)
            schedulePushToTalkReveal()

        case .recording(.gesturePending), .recording(.pushToTalk):
            guard let lastQuickFnReleaseAt,
                  timestamp - lastQuickFnReleaseAt <= doubleTapInterval,
                  pendingPushToTalkAcceptance != nil else { return }

            pendingPushToTalkAcceptance?.cancel()
            pendingPushToTalkAcceptance = nil
            pushToTalkRevealTask?.cancel()
            pushToTalkRevealTask = nil
            self.lastQuickFnReleaseAt = nil
            fnPressedAt = timestamp
            fnHoldReconciler.reset()
            phase = .recording(.continuous)
            WordmateLog.dictation.info("Recording \(self.recordingID, privacy: .public) switched to continuous mode")

        case .recording(.continuous):
            fnPressedAt = timestamp
            beginAutomaticAcceptance()

        case .processing, .success, .failure:
            break
        }
    }

    private func handleFnRelease(at timestamp: TimeInterval) {
        defer { fnPressedAt = nil }

        guard let fnPressedAt else { return }
        switch phase {
        case .recording(.gesturePending), .recording(.pushToTalk):
            break
        default:
            return
        }

        pushToTalkRevealTask?.cancel()
        pushToTalkRevealTask = nil

        let heldDuration = timestamp - fnPressedAt
        if heldDuration > quickTapMaximumDuration {
            lastQuickFnReleaseAt = nil
            beginAutomaticAcceptance()
            return
        }

        lastQuickFnReleaseAt = timestamp
        pendingPushToTalkAcceptance?.cancel()
        let acceptanceDelay = doubleTapInterval
        pendingPushToTalkAcceptance = Task { [weak self] in
            try? await Task.sleep(for: .seconds(acceptanceDelay))
            guard !Task.isCancelled,
                  let self,
                  self.isWaitingForFnDecision else { return }
            self.lastQuickFnReleaseAt = nil
            self.pendingPushToTalkAcceptance = nil
            await self.accept()
        }
    }

    /// A failure is shown long enough to read, but the next gesture must not
    /// have to wait for it.
    private func clearFailureIfNeeded() {
        guard case .failure = phase else { return }
        resetTask?.cancel()
        resetTask = nil
        phase = .idle
    }

    private func beginRecording(mode: RecordingMode) {
        guard phase == .idle else { return }

        resetTask?.cancel()
        operationID = nil
        recordingID = UUID()
        targetPID = frontmostExternalApplicationPID()

        cancelLivePipeline()
        let capture = LiveAudioCapture()
        let polisher = StreamingTranscriptPolisher(
            isEnabled: preferences.postProcessingEnabled,
            model: Self.postProcessingModel,
            processor: transcriptPostProcessor
        )
        let modelRunner = self.modelRunner
        let pipelineTask = Task(priority: .userInitiated) {
            let rawTranscript = TranscriptCleaner.clean(
                try await modelRunner.transcribeStreaming(
                    capture.stream,
                    using: Self.transcriptionEngine
                ) { stableSegment in
                    await polisher.consumeStableSegment(stableSegment)
                }
            )
            return await polisher.finalize(rawTranscript: rawTranscript)
        }
        liveAudioCapture = capture
        livePolisher = polisher
        livePipelineTask = pipelineTask

        let recordingID = self.recordingID
        WordmateLog.dictation.info(
            "Recording \(recordingID, privacy: .public) starting in \(String(describing: mode), privacy: .public) mode"
        )
        do {
            isMicrophoneLive = false
            try recorder.startWhenAuthorized(
                preferredDeviceUID: preferences.selectedInputDeviceUID,
                bufferHandler: { buffer in
                    capture.receive(buffer)
                },
                onEvent: { [weak self] event in
                    self?.handleRecorderEvent(event, recordingID: recordingID)
                }
            )
            audioLevel = 0
            phase = .recording(mode)
            beginMetering()
        } catch {
            cancelLivePipeline()
            targetPID = nil
            showFailure(error)
        }
    }

    private func handleRecorderEvent(_ event: MicrophoneRecorderEvent, recordingID: UUID) {
        guard recordingID == self.recordingID else { return }
        switch event {
        case let .started(device, sampleRate, channels, attempt):
            WordmateLog.dictation.info(
                "Recording \(recordingID, privacy: .public): microphone \(device, privacy: .public) running at \(sampleRate, privacy: .public) Hz \(channels, privacy: .public) ch (attempt \(attempt, privacy: .public))"
            )
        case let .firstBuffer(latency):
            WordmateLog.dictation.info(
                "Recording \(recordingID, privacy: .public): first audio after \(latency, privacy: .public) s"
            )
        case let .configurationChanged(sampleRate, channels):
            WordmateLog.dictation.info(
                "Recording \(recordingID, privacy: .public): input changed to \(sampleRate, privacy: .public) Hz \(channels, privacy: .public) ch, capture re-armed"
            )
        case let .recovered(rebuild):
            WordmateLog.dictation.info(
                "Recording \(recordingID, privacy: .public): capture rebuilt (\(rebuild, privacy: .public))"
            )
        case let .failed(message):
            handleMicrophoneFailure(LocalTranscriberError.microphoneUnavailable(message))
        }
    }

    /// The input device failed after the recording had been shown as active.
    /// The recorder has torn itself down; abandon the take visibly.
    private func handleMicrophoneFailure(_ error: Error) {
        guard case .recording = phase else { return }
        WordmateLog.dictation.error(
            "Recording \(self.recordingID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
        )
        cancelInteractionTasks()
        stopMetering()
        cancelLivePipeline()
        isMicrophoneLive = false
        targetPID = nil
        showFailure(error)
    }

    private func beginAutomaticAcceptance() {
        cancelInteractionTasks()
        Task { [weak self] in
            await self?.accept()
        }
    }

    private func cancelLivePipeline() {
        liveAudioCapture?.finish()
        liveAudioCapture = nil
        livePipelineTask?.cancel()
        livePipelineTask = nil
        if let polisher = livePolisher {
            Task { await polisher.cancel() }
        }
        livePolisher = nil
    }

    private func processBatchRecording(
        _ recording: AudioRecording
    ) async throws -> LiveDictationResult {
        let samples = try await Task.detached(priority: .userInitiated) {
            try AudioSampleLoader.loadMono16k(from: recording.fileURL)
        }.value
        guard samples.count >= 1_600 else {
            throw LocalTranscriberError.recordingTooShort
        }

        try await modelRunner.prepare(Self.transcriptionEngine)
        let rawTranscript = TranscriptCleaner.clean(
            try await modelRunner.transcribe(samples, using: Self.transcriptionEngine)
        )
        guard !rawTranscript.isEmpty else {
            throw LocalTranscriberError.noSpeechDetected
        }

        guard preferences.postProcessingEnabled else {
            return LiveDictationResult(
                rawTranscript: rawTranscript,
                transcript: rawTranscript
            )
        }

        let transcript: String
        do {
            transcript = try await transcriptPostProcessor.polish(
                rawTranscript,
                using: Self.postProcessingModel
            )
        } catch {
            // Post-processing is optional. Never lose a completed dictation
            // because the local language model could not improve it.
            transcript = rawTranscript
        }
        let formatted = SpokenNumberFormatter.format(transcript)
        return LiveDictationResult(
            rawTranscript: rawTranscript,
            transcript: TranscriptPolishPolicy.applyingParagraphBreaks(
                to: formatted,
                startingAt: ParagraphPlanner.paragraphStarts(in: formatted)
            )
        )
    }

    private func cancelInteractionTasks() {
        pendingPushToTalkAcceptance?.cancel()
        pushToTalkRevealTask?.cancel()
        pendingPushToTalkAcceptance = nil
        pushToTalkRevealTask = nil
        fnPressedAt = nil
        lastQuickFnReleaseAt = nil
        fnHoldReconciler.reset()
    }

    private func schedulePushToTalkReveal() {
        pushToTalkRevealTask?.cancel()
        let revealDelay = pushToTalkRevealDelay
        pushToTalkRevealTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(revealDelay))
            guard !Task.isCancelled,
                  let self,
                  self.phase == .recording(.gesturePending),
                  self.fnPressedAt != nil else { return }
            self.pushToTalkRevealTask = nil
            self.phase = .recording(.pushToTalk)
        }
    }

    private var isWaitingForFnDecision: Bool {
        phase == .recording(.gesturePending) || phase == .recording(.pushToTalk)
    }

    private func stopMetering() {
        meterTask?.cancel()
        meterTask = nil
    }

    private func beginMetering() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard case .recording = self.phase else { return }

                self.updateMicrophoneLiveness()
                self.reconcileFnHold()

                let measuredLevel = self.recorder.currentLevel()
                let response = measuredLevel > self.audioLevel ? 0.68 : 0.24
                let smoothedLevel = self.audioLevel
                    + ((measuredLevel - self.audioLevel) * response)
                self.audioLevel = smoothedLevel < 0.015 ? 0 : smoothedLevel
                try? await Task.sleep(for: .milliseconds(36))
            }
        }
    }

    private func updateMicrophoneLiveness() {
        guard !isMicrophoneLive, recorder.hasReceivedNonZeroAudio else { return }
        isMicrophoneLive = true
    }

    /// Ends a push-to-talk hold whose Fn release event never arrived.
    private func reconcileFnHold() {
        guard isWaitingForFnDecision, fnPressedAt != nil else { return }
        let pressed = CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn)
        let now = ProcessInfo.processInfo.systemUptime
        guard fnHoldReconciler.observe(fnPhysicallyPressed: pressed, at: now) else { return }
        WordmateLog.dictation.error(
            "Recording \(self.recordingID, privacy: .public): Fn release event was lost; ending the hold"
        )
        fnHoldReconciler.reset()
        onFnHoldLost?()
        handleFnRelease(at: now)
    }

    private func showFailure(_ error: Error) {
        cancelInteractionTasks()
        let message = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription

        // A take with nothing in it is not a failure worth a warning: the
        // notch simply closes, the same as a discard.
        if Self.isEmptyTake(error) {
            WordmateLog.dictation.info("Dictation ended without speech: \(message, privacy: .public)")
            phase = .idle
            return
        }

        WordmateLog.dictation.error("Dictation failed: \(message, privacy: .public)")
        phase = .failure(message)
        scheduleReset(after: failureDisplayDuration)
    }

    private static func isEmptyTake(_ error: Error) -> Bool {
        guard let error = error as? LocalTranscriberError else { return false }
        switch error {
        case .noSpeechDetected, .recordingTooShort, .emptyRecording:
            return true
        default:
            return false
        }
    }

    private func scheduleReset(after duration: Duration) {
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.phase = .idle
        }
    }

    private func frontmostExternalApplicationPID() -> pid_t? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        return application.processIdentifier
    }
}
