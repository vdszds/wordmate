import AppKit
import Combine
import SwiftUI

@MainActor
final class AppCoordinator: NSObject {
    private let preferences = AppPreferences()
    private let modelRunner = ModelRunner()
    private let transcriptPostProcessor = TranscriptPostProcessor()
    private let shortcutMonitor = FnShortcutMonitor()
    private let appUpdater = AppUpdater()
    private let usageStatistics = UsageStatistics()

    private lazy var postProcessingReadiness = PostProcessingReadiness(
        processor: transcriptPostProcessor,
        model: .qwen3_0_6b
    )
    private lazy var dictationController = DictationController(
        preferences: preferences,
        modelRunner: modelRunner,
        transcriptPostProcessor: transcriptPostProcessor,
        postProcessingReadiness: postProcessingReadiness,
        usageStatistics: usageStatistics
    )
    private lazy var pillWindowController = PillWindowController(
        controller: dictationController
    )
    private lazy var fileTranscriptionViewModel = FileTranscriptionViewModel(
        transcriber: AudioFileTranscriber(
            modelRunner: modelRunner,
            processor: transcriptPostProcessor,
            engine: .parakeet,
            postProcessingModel: .qwen3_0_6b
        ),
        preferences: preferences,
        readiness: postProcessingReadiness,
        usageStatistics: usageStatistics
    )

    private var onboardingWindow: NSWindow?
    private var onboardingViewModel: OnboardingViewModel?
    private var homeWindow: NSWindow?
    private var homeViewModel: HomeViewModel?
    private var statusItem: NSStatusItem?
    private var dictationPhaseSubscription: AnyCancellable?

    func start() {
        if preferences.hasCompletedOnboarding && requiredModelsAreDownloaded {
            enterBackgroundMode()
            showHome()
        } else {
            showOnboarding()
        }
    }

    func stop() {
        stopShortcutMonitoring()
        dictationController.stop()
        fileTranscriptionViewModel.cancel()
        pillWindowController.close()
        removeStatusItem()
        homeWindow?.close()
        onboardingWindow?.close()
    }

    func showPrimaryWindow() {
        if onboardingWindow?.isVisible == true
            || !preferences.hasCompletedOnboarding
            || !requiredModelsAreDownloaded {
            showOnboarding()
        } else {
            showHome()
        }
    }

    func showOnboarding() {
        stopShortcutMonitoring()
        dictationController.stop()
        fileTranscriptionViewModel.cancel()
        pillWindowController.hide()
        removeStatusItem()
        homeWindow?.orderOut(nil)
        NSApp.setActivationPolicy(.regular)

        if let onboardingWindow {
            onboardingWindow.center()
            onboardingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let viewModel = OnboardingViewModel(
            preferences: preferences,
            modelRunner: modelRunner,
            transcriptPostProcessor: transcriptPostProcessor
        ) { [weak self] in
            self?.completeOnboarding()
        }
        onboardingViewModel = viewModel

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 540),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Wordmate Setup"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentViewController = NSHostingController(
            rootView: OnboardingView(viewModel: viewModel)
        )
        window.center()

        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func completeOnboarding() {
        preferences.hasCompletedOnboarding = true
        onboardingWindow?.orderOut(nil)
        onboardingWindow?.close()
        onboardingWindow = nil
        onboardingViewModel = nil
        enterBackgroundMode()
        showHome()
    }

    private func enterBackgroundMode() {
        NSApp.setActivationPolicy(.regular)
        // Installs completed before this step existed in onboarding still have
        // the system Fn shortcut fighting the dictation gestures. Fix it once;
        // after that the user's own Keyboard Settings choice wins.
        if !preferences.hasDisabledSystemFnShortcut,
           FnUsagePreference.disableSystemShortcut() {
            preferences.hasDisabledSystemFnShortcut = true
        }
        installStatusItem()
        pillWindowController.show()
        appUpdater.startIfConfigured()
        observeDictationPhaseForShortcuts()
        dictationController.onFnHoldLost = { [weak self] in
            self?.shortcutMonitor.resetPressedState()
        }
        shortcutMonitor.start { [weak self] event in
            switch event {
            case let .fn(transition):
                self?.dictationController.handleFnTransition(transition)
            case .discardContinuousRecording:
                self?.dictationController.discardContinuousRecording()
            }
        }
        dictationController.warmModels()
    }

    private func showHome() {
        guard preferences.hasCompletedOnboarding,
              requiredModelsAreDownloaded else {
            showOnboarding()
            return
        }

        NSApp.setActivationPolicy(.regular)

        if let homeWindow {
            homeViewModel?.refresh()
            homeWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let viewModel = HomeViewModel(
            preferences: preferences,
            readiness: postProcessingReadiness
        )
        homeViewModel = viewModel

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 460),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )
        window.title = "Wordmate"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentViewController = NSHostingController(
            rootView: HomeView(
                viewModel: viewModel,
                statistics: usageStatistics,
                updater: appUpdater,
                fileTranscription: fileTranscriptionViewModel
            )
        )
        window.center()

        homeWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func observeDictationPhaseForShortcuts() {
        dictationPhaseSubscription?.cancel()
        dictationPhaseSubscription = dictationController.$phase
            .map { $0 == .recording(.continuous) }
            .removeDuplicates()
            .sink { [weak self] shouldCaptureEscape in
                self?.shortcutMonitor.setEscapeCaptureEnabled(shouldCaptureEscape)
            }
    }

    private func stopShortcutMonitoring() {
        dictationPhaseSubscription?.cancel()
        dictationPhaseSubscription = nil
        shortcutMonitor.setEscapeCaptureEnabled(false)
        shortcutMonitor.stop()
    }

    private func installStatusItem() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        }

        if let button = statusItem?.button {
            let iconURL = Bundle.main.url(
                forResource: "WordmateMenuBarTemplate",
                withExtension: "png"
            )
            let icon = iconURL.flatMap(NSImage.init(contentsOf:))
            icon?.size = NSSize(width: 18, height: 18)
            icon?.isTemplate = true
            icon?.accessibilityDescription = "Wordmate"
            button.image = icon ?? NSImage(
                systemSymbolName: "waveform.badge.mic",
                accessibilityDescription: "Wordmate"
            )
            button.imageScaling = .scaleProportionallyUpOrDown
            button.toolTip = "Wordmate"
        }

        let menu = NSMenu()
        menu.delegate = self
        rebuildStatusMenu(menu)
        statusItem?.menu = menu
    }

    private func rebuildStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let versionItem = NSMenuItem(
            title: "Wordmate \(AppUpdater.versionDescription)",
            action: nil,
            keyEquivalent: ""
        )
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(.separator())

        let microphoneItem = NSMenuItem(
            title: "Microphone",
            action: nil,
            keyEquivalent: ""
        )
        microphoneItem.submenu = makeMicrophoneMenu()
        menu.addItem(microphoneItem)
        menu.addItem(.separator())

        let startItem = NSMenuItem(
            title: "Start Recording",
            action: #selector(startRecordingFromMenu),
            keyEquivalent: ""
        )
        startItem.target = self
        menu.addItem(startItem)

        let updateItem = NSMenuItem(
            title: AppUpdater.menuTitle(for: appUpdater.status),
            action: #selector(AppUpdater.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = appUpdater
        updateItem.isEnabled = AppUpdater.menuItemIsEnabled(for: appUpdater.status)
        menu.addItem(updateItem)

        let setupItem = NSMenuItem(
            title: "Run Setup Again…",
            action: #selector(runSetupAgain),
            keyEquivalent: ""
        )
        setupItem.target = self
        menu.addItem(setupItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Wordmate",
            action: #selector(quitApplication),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private var requiredModelsAreDownloaded: Bool {
        ModelRunner.isModelDownloaded(.parakeet)
            && TranscriptPostProcessor.isModelDownloaded(.qwen3_0_6b)
    }

    private func makeMicrophoneMenu() -> NSMenu {
        let menu = NSMenu(title: "Microphone")
        let devices = AudioInputDeviceManager.availableDevices()
        let selectedUID = preferences.selectedInputDeviceUID
        let defaultDeviceName = AudioInputDeviceManager.defaultInputDevice()?.name

        let defaultTitle = defaultDeviceName.map {
            "System Default — \($0)"
        } ?? "System Default"
        let defaultItem = NSMenuItem(
            title: defaultTitle,
            action: #selector(selectMicrophone(_:)),
            keyEquivalent: ""
        )
        defaultItem.target = self
        defaultItem.tag = 0
        defaultItem.state = selectedUID == nil ? .on : .off
        menu.addItem(defaultItem)

        if !devices.isEmpty {
            menu.addItem(.separator())
        }

        for device in devices {
            let item = NSMenuItem(
                title: device.name,
                action: #selector(selectMicrophone(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = 1
            item.representedObject = device.id
            item.state = selectedUID == device.id ? .on : .off
            menu.addItem(item)
        }

        if let selectedUID,
           !devices.contains(where: { $0.id == selectedUID }) {
            menu.addItem(.separator())
            let disconnectedItem = NSMenuItem(
                title: "\(preferences.selectedInputDeviceName ?? "Selected microphone") — Disconnected",
                action: nil,
                keyEquivalent: ""
            )
            disconnectedItem.state = .on
            disconnectedItem.isEnabled = false
            menu.addItem(disconnectedItem)
        }

        return menu
    }

    private func removeStatusItem() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    @objc private func startRecordingFromMenu() {
        dictationController.startContinuousRecording()
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard sender.tag == 1,
              let uid = sender.representedObject as? String else {
            preferences.selectedInputDeviceUID = nil
            preferences.selectedInputDeviceName = nil
            return
        }

        preferences.selectedInputDeviceUID = uid
        preferences.selectedInputDeviceName = sender.title
    }

    @objc private func runSetupAgain() {
        showOnboarding()
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }
}

extension AppCoordinator: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildStatusMenu(menu)
    }
}
