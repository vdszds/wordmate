import AppKit
import Combine
import Foundation

@MainActor
final class OnboardingViewModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case output
        case download
        case microphone
        case accessibility
        case ready
    }

    enum NavigationDirection: Equatable {
        case forward
        case backward
    }

    enum DownloadState: Equatable {
        case idle
        case downloading
        case ready
        case failed(String)
    }

    @Published private(set) var step: Step = .output
    private(set) var navigationDirection: NavigationDirection = .forward
    @Published private(set) var postProcessingEnabled: Bool
    @Published private(set) var downloadState: DownloadState = .idle
    @Published private(set) var transcriptionProgress = 0.0
    @Published private(set) var transcriptionStatus = "Waiting to download"
    @Published private(set) var postProcessingProgress = 0.0
    @Published private(set) var postProcessingStatus = "Waiting to download"
    @Published private(set) var microphoneGranted: Bool
    @Published private(set) var microphoneLevel = 0.0
    @Published private(set) var accessibilityGranted: Bool
    @Published private(set) var accessibilityRequestStarted = false
    @Published private(set) var showAccessibilityTroubleshooting = false

    private let preferences: AppPreferences
    private let modelRunner: ModelRunner
    private let transcriptPostProcessor: TranscriptPostProcessor
    private let completion: () -> Void
    private let microphoneMonitor = MicrophoneLevelMonitor()
    private var modelPreparationTask: Task<Void, Never>?
    private var modelPreparationOperationID: UUID?
    private var permissionPollTask: Task<Void, Never>?
    private var applicationActivationObserver: NSObjectProtocol?

    init(
        preferences: AppPreferences,
        modelRunner: ModelRunner,
        transcriptPostProcessor: TranscriptPostProcessor,
        completion: @escaping () -> Void
    ) {
        self.preferences = preferences
        self.modelRunner = modelRunner
        self.transcriptPostProcessor = transcriptPostProcessor
        self.completion = completion
        postProcessingEnabled = preferences.postProcessingEnabled
        microphoneGranted = SystemPermissions.microphone == .granted
        accessibilityGranted = SystemPermissions.accessibilityGranted

        let transcriptionDownloaded = ModelRunner.isModelDownloaded(.parakeet)
        let postProcessingDownloaded = TranscriptPostProcessor.isModelDownloaded(.qwen3_0_6b)
        transcriptionProgress = transcriptionDownloaded ? 1 : 0
        transcriptionStatus = transcriptionDownloaded ? "Ready" : "Waiting to download"
        postProcessingProgress = postProcessingDownloaded ? 1 : 0
        postProcessingStatus = postProcessingDownloaded ? "Ready" : "Waiting to download"
        if transcriptionDownloaded && postProcessingDownloaded {
            downloadState = .ready
        }

        applicationActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAccessibilityPermission()
            }
        }
    }

    deinit {
        modelPreparationTask?.cancel()
        permissionPollTask?.cancel()
        if let applicationActivationObserver {
            NotificationCenter.default.removeObserver(applicationActivationObserver)
        }
    }

    var combinedDownloadProgress: Double {
        (transcriptionProgress + postProcessingProgress) / 2
    }

    var downloadError: String? {
        guard case let .failed(message) = downloadState else { return nil }
        return message
    }

    var canContinueFromDownload: Bool {
        downloadState == .ready
    }

    func setPostProcessingEnabled(_ enabled: Bool) {
        guard enabled != postProcessingEnabled else { return }
        postProcessingEnabled = enabled
        preferences.postProcessingEnabled = enabled

        if !enabled, downloadState == .ready {
            Task {
                await transcriptPostProcessor.cancelPreparationAndUnload()
            }
        }
    }

    func retryDownloads() {
        guard downloadState != .downloading else { return }
        startModelDownloads()
    }

    func next() {
        switch step {
        case .output:
            move(to: .download)
            if downloadState != .ready {
                startModelDownloads()
            }
        case .download where canContinueFromDownload:
            move(to: .microphone)
        case .microphone where microphoneGranted:
            move(to: .accessibility)
        case .accessibility where accessibilityGranted:
            move(to: .ready)
        case .ready:
            permissionPollTask?.cancel()
            completion()
        default:
            break
        }
    }

    func back() {
        guard downloadState != .downloading || step != .download,
              let previous = Step(rawValue: step.rawValue - 1) else { return }
        move(to: previous)
    }

    func requestMicrophone() {
        if SystemPermissions.microphone == .denied {
            SystemPermissions.openMicrophoneSettings()
            beginPermissionPolling()
            return
        }

        Task {
            microphoneGranted = await SystemPermissions.requestMicrophone()
            if !microphoneGranted,
               SystemPermissions.microphone == .denied {
                SystemPermissions.openMicrophoneSettings()
            }
            updateMicrophoneTest()
            beginPermissionPolling()
        }
    }

    func requestAccessibility() {
        refreshAccessibilityPermission()
        if accessibilityGranted {
            return
        }

        if accessibilityRequestStarted {
            showAccessibilityTroubleshooting = true
        } else {
            accessibilityRequestStarted = true
            showAccessibilityTroubleshooting = false
            SystemPermissions.requestAccessibility()
        }
        beginPermissionPolling()
    }

    func openAccessibilitySettings() {
        SystemPermissions.openAccessibilitySettings()
    }

    var accessibilityButtonTitle: String {
        accessibilityRequestStarted ? "Check Permission" : "Enable Accessibility"
    }

    private func startModelDownloads() {
        modelPreparationTask?.cancel()
        let operationID = UUID()
        modelPreparationOperationID = operationID
        downloadState = .downloading
        transcriptionProgress = ModelRunner.isModelDownloaded(.parakeet) ? 1 : 0
        transcriptionStatus = transcriptionProgress == 1 ? "Preparing…" : "Starting download…"
        postProcessingProgress = TranscriptPostProcessor.isModelDownloaded(.qwen3_0_6b) ? 1 : 0
        postProcessingStatus = postProcessingProgress == 1 ? "Preparing…" : "Starting download…"

        modelPreparationTask = Task { [weak self] in
            guard let self else { return }

            async let transcriptionError = self.prepareTranscriptionModel(
                operationID: operationID
            )
            async let postProcessingError = self.preparePostProcessingModel(
                operationID: operationID
            )
            let errors = await (transcriptionError, postProcessingError)

            guard self.modelPreparationOperationID == operationID,
                  !Task.isCancelled else { return }

            let messages = [errors.0, errors.1].compactMap { $0 }
            guard messages.isEmpty else {
                self.downloadState = .failed(messages.joined(separator: "\n"))
                self.modelPreparationTask = nil
                return
            }

            if !self.postProcessingEnabled {
                await self.transcriptPostProcessor.cancelPreparationAndUnload()
            }
            guard self.modelPreparationOperationID == operationID else { return }
            self.downloadState = .ready
            self.modelPreparationTask = nil
        }
    }

    private func prepareTranscriptionModel(operationID: UUID) async -> String? {
        do {
            try await modelRunner.prepare(.parakeet) { [weak self] update in
                Task { @MainActor in
                    guard let self,
                          self.modelPreparationOperationID == operationID else { return }
                    self.transcriptionProgress = update.fractionCompleted
                    self.transcriptionStatus = update.status
                }
            }
            guard modelPreparationOperationID == operationID else { return nil }
            transcriptionProgress = 1
            transcriptionStatus = "Ready"
            return nil
        } catch is CancellationError {
            return "Speech recognition download was cancelled."
        } catch {
            guard modelPreparationOperationID == operationID else { return nil }
            transcriptionStatus = "Download failed"
            return "Speech recognition: \(Self.errorMessage(for: error))"
        }
    }

    private func preparePostProcessingModel(operationID: UUID) async -> String? {
        do {
            try await transcriptPostProcessor.prepare(.qwen3_0_6b) { [weak self] update in
                Task { @MainActor in
                    guard let self,
                          self.modelPreparationOperationID == operationID else { return }
                    self.postProcessingProgress = update.fractionCompleted
                    self.postProcessingStatus = Self.postProcessingStatus(for: update)
                }
            }
            guard modelPreparationOperationID == operationID else { return nil }
            postProcessingProgress = 1
            postProcessingStatus = "Ready"
            return nil
        } catch is CancellationError {
            return "Text cleanup download was cancelled."
        } catch {
            guard modelPreparationOperationID == operationID else { return nil }
            postProcessingStatus = "Download failed"
            return "Text cleanup: \(Self.errorMessage(for: error))"
        }
    }

    private static func postProcessingStatus(for update: ModelPreparationUpdate) -> String {
        if update.fractionCompleted >= 1 {
            return "Ready"
        }
        if update.status.localizedCaseInsensitiveContains("download") {
            return "Downloading…"
        }
        if update.status.localizedCaseInsensitiveContains("load") {
            return "Finishing setup…"
        }
        return "Checking files…"
    }

    private static func errorMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func move(to newStep: Step) {
        permissionPollTask?.cancel()
        microphoneMonitor.stop()
        navigationDirection = newStep.rawValue < step.rawValue ? .backward : .forward
        step = newStep
        microphoneGranted = SystemPermissions.microphone == .granted
        accessibilityGranted = SystemPermissions.accessibilityGranted
        if accessibilityGranted {
            showAccessibilityTroubleshooting = false
        }
        if newStep == .microphone || newStep == .accessibility {
            beginPermissionPolling()
        }
        updateMicrophoneTest()
    }

    private func beginPermissionPolling() {
        permissionPollTask?.cancel()
        permissionPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.microphoneGranted = SystemPermissions.microphone == .granted
                self.refreshAccessibilityPermission()
                self.updateMicrophoneTest()
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
    }

    private func refreshAccessibilityPermission() {
        accessibilityGranted = SystemPermissions.accessibilityGranted
        if accessibilityGranted {
            showAccessibilityTroubleshooting = false
        }
    }

    private func updateMicrophoneTest() {
        guard step == .microphone, microphoneGranted else {
            microphoneMonitor.stop()
            microphoneLevel = 0
            return
        }
        guard !microphoneMonitor.isRunning else { return }

        microphoneLevel = 0
        try? microphoneMonitor.start(
            preferredDeviceUID: preferences.selectedInputDeviceUID
        ) { [weak self] level in
            Task { @MainActor in
                guard let self, self.step == .microphone else { return }
                self.microphoneLevel = level
            }
        }
    }
}
