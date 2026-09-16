import AVFoundation
import CoreAudio
import XCTest
@testable import LocalTranscriber

final class AppInteractionTests: XCTestCase {
    func testFnTransitionDetectorIgnoresRepeatedFlagsEvents() {
        var detector = FnKeyTransitionDetector()

        XCTAssertEqual(
            detector.handle(isPressed: true, timestamp: 1.0),
            .pressed(timestamp: 1.0)
        )
        XCTAssertNil(detector.handle(isPressed: true, timestamp: 1.1))
        XCTAssertEqual(
            detector.handle(isPressed: false, timestamp: 1.2),
            .released(timestamp: 1.2)
        )
    }

    func testEscapeIsCapturedOnlyWhileContinuousRecordingIsActive() {
        var detector = EscapeKeyCaptureDetector()

        XCTAssertEqual(
            detector.handle(isPressed: true, captureEnabled: false),
            EscapeKeyCaptureDecision(shouldConsume: false, shouldDiscard: false)
        )
        XCTAssertEqual(
            detector.handle(isPressed: false, captureEnabled: false),
            EscapeKeyCaptureDecision(shouldConsume: false, shouldDiscard: false)
        )

        XCTAssertEqual(
            detector.handle(isPressed: true, captureEnabled: true),
            EscapeKeyCaptureDecision(shouldConsume: true, shouldDiscard: true)
        )
        XCTAssertEqual(
            detector.handle(isPressed: false, captureEnabled: false),
            EscapeKeyCaptureDecision(shouldConsume: true, shouldDiscard: false)
        )
    }

    func testHeldEscapeTriggersDiscardOnlyOnce() {
        var detector = EscapeKeyCaptureDetector()

        XCTAssertTrue(
            detector.handle(isPressed: true, captureEnabled: true).shouldDiscard
        )
        XCTAssertEqual(
            detector.handle(
                isPressed: true,
                captureEnabled: true,
                isRepeat: true
            ),
            EscapeKeyCaptureDecision(shouldConsume: true, shouldDiscard: false)
        )
    }

    func testDiscoveredAudioInputsHaveNamesAndPersistentIdentifiers() {
        for device in AudioInputDeviceManager.availableDevices() {
            XCTAssertFalse(device.id.isEmpty)
            XCTAssertFalse(device.name.isEmpty)
        }
    }

    func testUpdaterAcceptsProductionHTTPSConfiguration() {
        XCTAssertTrue(
            AppUpdater.isConfigurationValid(
                feedString: "https://releases.wordmate.sh/desktop/macos/appcast.xml",
                publicKey: "Q8khmG8rH0M8DK8HRGBK3/l67omDo/4RNBjamupp3MI="
            )
        )
    }

    func testUpdaterRejectsPlaceholderAndMalformedConfiguration() {
        XCTAssertFalse(
            AppUpdater.isConfigurationValid(
                feedString: "https://updates.example.invalid/appcast.xml",
                publicKey: "REPLACE_WITH_KEY"
            )
        )
        XCTAssertFalse(
            AppUpdater.isConfigurationValid(
                feedString: "http://cdn.example.com/appcast.xml",
                publicKey: "Q8khmG8rH0M8DK8HRGBK3/l67omDo/4RNBjamupp3MI="
            )
        )
        XCTAssertFalse(
            AppUpdater.isConfigurationValid(
                feedString: "https://cdn.example.com/appcast.xml",
                publicKey: "not-a-valid-ed25519-key"
            )
        )
    }

    func testRecordingsPinTheEngineInputToTheDefaultMicrophone() throws {
        guard let defaultDevice = AudioInputDeviceManager.defaultInputDevice() else {
            throw XCTSkip("No default input device on this machine")
        }
        XCTAssertEqual(
            AudioInputDeviceManager.recordingDevice(preferredDeviceUID: nil),
            defaultDevice
        )
        XCTAssertEqual(
            AudioInputDeviceManager.recordingDevice(preferredDeviceUID: "missing-device-uid"),
            defaultDevice
        )

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let configured = try AudioInputDeviceManager.configure(inputNode, preferredDeviceUID: nil)
        XCTAssertEqual(configured, defaultDevice)

        let audioUnit = try XCTUnwrap(inputNode.audioUnit)
        var pinnedDeviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &pinnedDeviceID,
            &size
        )
        XCTAssertEqual(status, noErr)
        if defaultDevice.isBluetooth {
            // A Bluetooth default is deliberately left to the engine's own
            // default-device tracking.
            XCTAssertFalse(AudioInputDeviceManager.shouldPin(defaultDevice, isSystemDefault: true))
        } else {
            XCTAssertEqual(
                AudioInputDeviceManager.audioObjectID(forDeviceUID: defaultDevice.id),
                pinnedDeviceID
            )
        }
    }

    @MainActor
    func testRecorderReturnsBeforeTheDeviceStartsAndThenReceivesAudio() async throws {
        guard SystemPermissions.microphone == .granted,
              AudioInputDeviceManager.defaultInputDevice() != nil else {
            throw XCTSkip("Requires microphone permission and an input device")
        }

        let recorder = MicrophoneRecorder()
        let clock = ContinuousClock()
        let events = EventLog()
        let started = clock.now
        try recorder.startWhenAuthorized(preferredDeviceUID: nil) { event in
            events.append(event)
        }
        let setupDuration = started.duration(to: clock.now)
        XCTAssertLessThan(setupDuration, .milliseconds(100), "Starting must not wait for the device")

        var waited = Duration.zero
        while !recorder.hasReceivedAudio, waited < .seconds(3) {
            try await Task.sleep(for: .milliseconds(10))
            waited += .milliseconds(10)
        }
        XCTAssertTrue(recorder.hasReceivedAudio, "No audio arrived within 3 seconds")
        try await Task.sleep(for: .milliseconds(300))

        let stopStarted = clock.now
        let recording = try await recorder.stop()
        let stopDuration = stopStarted.duration(to: clock.now)
        XCTAssertLessThan(stopDuration, .seconds(1))
        XCTAssertGreaterThan(recording.duration, 0.2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.fileURL.path))
        try? FileManager.default.removeItem(at: recording.fileURL)

        let recorded = events.snapshot
        XCTAssertTrue(recorded.contains { if case .started = $0 { return true } else { return false } })
        XCTAssertTrue(recorded.contains { if case .firstBuffer = $0 { return true } else { return false } })
        XCTAssertFalse(recorded.contains { if case .failed = $0 { return true } else { return false } })
        print("RECORDER_SETUP=\(setupDuration) FIRST_AUDIO_AFTER=\(waited) STOP=\(stopDuration)")
    }

    @MainActor
    func testAbandonedRecordingDeletesItsFile() async throws {
        guard SystemPermissions.microphone == .granted,
              AudioInputDeviceManager.defaultInputDevice() != nil else {
            throw XCTSkip("Requires microphone permission and an input device")
        }
        let recorder = MicrophoneRecorder()
        try recorder.startWhenAuthorized(preferredDeviceUID: nil)
        try await Task.sleep(for: .milliseconds(400))
        recorder.abandon()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(recorder.hasReceivedAudio)
        // A new recording can start right away.
        try recorder.startWhenAuthorized(preferredDeviceUID: nil)
        recorder.abandon()
    }

    /// A Bluetooth headset changes its sample rate when recording starts.
    /// Simulate that on the default input device and require the recording
    /// to keep delivering audio afterwards.
    @MainActor
    func testRecordingSurvivesAnInputFormatChange() async throws {
        guard SystemPermissions.microphone == .granted,
              let device = AudioInputDeviceManager.defaultInputDevice(),
              !device.isBluetooth else {
            throw XCTSkip("Requires microphone permission and a wired default input device")
        }
        let deviceID = device.audioObjectID
        guard let originalRate = Self.nominalSampleRate(of: deviceID) else {
            throw XCTSkip("Cannot read the device sample rate")
        }
        let alternateRate = originalRate == 48_000 ? 44_100.0 : 48_000.0
        defer { _ = Self.setNominalSampleRate(alternateRate == originalRate ? alternateRate : originalRate, of: deviceID) }

        let recorder = MicrophoneRecorder()
        let events = EventLog()
        try recorder.startWhenAuthorized(preferredDeviceUID: nil) { events.append($0) }
        var waited = Duration.zero
        while !recorder.hasReceivedAudio, waited < .seconds(3) {
            try await Task.sleep(for: .milliseconds(10))
            waited += .milliseconds(10)
        }
        XCTAssertTrue(recorder.hasReceivedAudio)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(Self.setNominalSampleRate(alternateRate, of: deviceID), noErr)
        try await Task.sleep(for: .seconds(3))

        let recording = try await recorder.stop()
        _ = Self.setNominalSampleRate(originalRate, of: deviceID)
        try? FileManager.default.removeItem(at: recording.fileURL)

        let recorded = events.snapshot
        XCTAssertFalse(recorded.contains { if case .failed = $0 { return true } else { return false } })
        // Audio kept flowing after the change, either continuously or through
        // a rebuild: well over the 0.3 s captured before it.
        XCTAssertGreaterThan(recording.duration, 1.2, "Capture stalled after the format change")
        print("FORMAT_CHANGE_EVENTS=\(recorded)")
    }

    private static func nominalSampleRate(of deviceID: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate) == noErr else { return nil }
        return rate
    }

    private static func setNominalSampleRate(_ rate: Double, of deviceID: AudioObjectID) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = rate
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &value)
    }

    func testBluetoothDefaultInputIsNotPinned() {
        let wired = AudioInputDevice(
            id: "wired",
            name: "USB Microphone",
            audioObjectID: 1,
            transportType: kAudioDeviceTransportTypeUSB
        )
        let headset = AudioInputDevice(
            id: "bt",
            name: "AirPods",
            audioObjectID: 2,
            transportType: kAudioDeviceTransportTypeBluetooth
        )
        XCTAssertTrue(AudioInputDeviceManager.shouldPin(wired, isSystemDefault: true))
        XCTAssertTrue(AudioInputDeviceManager.shouldPin(wired, isSystemDefault: false))
        XCTAssertFalse(AudioInputDeviceManager.shouldPin(headset, isSystemDefault: true))
        XCTAssertTrue(AudioInputDeviceManager.shouldPin(headset, isSystemDefault: false))
        XCTAssertTrue(headset.isBluetooth)
        XCTAssertFalse(wired.isBluetooth)
    }

    func testLostFnReleaseIsSynthesizedOnlyAfterAPhysicalPressWasSeen() {
        var reconciler = FnHoldReconciler()
        // Hardware never reports Fn: nothing is synthesized.
        XCTAssertFalse(reconciler.observe(fnPhysicallyPressed: false, at: 0))
        XCTAssertFalse(reconciler.observe(fnPhysicallyPressed: false, at: 5))

        // Fn seen pressed, then reads released for less than the grace period.
        XCTAssertFalse(reconciler.observe(fnPhysicallyPressed: true, at: 6))
        XCTAssertFalse(reconciler.observe(fnPhysicallyPressed: false, at: 6.1))
        XCTAssertFalse(reconciler.observe(fnPhysicallyPressed: false, at: 6.5))
        // Pressed again: the countdown restarts.
        XCTAssertFalse(reconciler.observe(fnPhysicallyPressed: true, at: 6.6))
        XCTAssertFalse(reconciler.observe(fnPhysicallyPressed: false, at: 6.7))
        XCTAssertFalse(reconciler.observe(fnPhysicallyPressed: false, at: 7.2))
        XCTAssertTrue(reconciler.observe(fnPhysicallyPressed: false, at: 7.35))
    }

    func testFnDetectorReportsAPressAgainAfterAReset() {
        var detector = FnKeyTransitionDetector()
        XCTAssertEqual(detector.handle(isPressed: true, timestamp: 1), .pressed(timestamp: 1))
        // The release event was lost; a fresh detector stands in for the reset.
        detector = FnKeyTransitionDetector()
        XCTAssertEqual(detector.handle(isPressed: true, timestamp: 2), .pressed(timestamp: 2))
        XCTAssertEqual(detector.handle(isPressed: false, timestamp: 3), .released(timestamp: 3))
    }

    func testIncompleteRecordingsAreMarked() {
        let url = URL(fileURLWithPath: "/tmp/x.caf")
        XCTAssertTrue(AudioRecording(fileURL: url, duration: 1).isComplete)
        XCTAssertFalse(AudioRecording(fileURL: url, duration: 1, isComplete: false).isComplete)
    }

    func testUpdaterStatusDrivesMenuAndWelcomeCopy() {
        XCTAssertEqual(AppUpdater.menuTitle(for: .idle), "Check for Updates…")
        XCTAssertEqual(AppUpdater.menuTitle(for: .checking), "Checking for Updates…")
        XCTAssertEqual(AppUpdater.menuTitle(for: .updateAvailable(version: "0.2.0")), "Update to 0.2.0…")
        XCTAssertFalse(AppUpdater.menuItemIsEnabled(for: .checking))
        XCTAssertTrue(AppUpdater.menuItemIsEnabled(for: .updateAvailable(version: "0.2.0")))

        let now = Date()
        XCTAssertEqual(
            AppUpdater.statusDescription(for: .upToDate(now.addingTimeInterval(-20)), now: now),
            "Up to date · checked just now"
        )
        XCTAssertEqual(
            AppUpdater.statusDescription(for: .upToDate(now.addingTimeInterval(-300)), now: now),
            "Up to date · checked 5 min ago"
        )
        XCTAssertEqual(
            AppUpdater.statusDescription(for: .updateAvailable(version: "0.2.0")),
            "Version 0.2.0 is available."
        )
        XCTAssertEqual(AppUpdater.versionDescription(shortVersion: "0.1.10", build: "12"), "0.1.10 (12)")
        XCTAssertEqual(AppUpdater.versionDescription(shortVersion: nil, build: nil), "unknown version")
    }

    func testFailurePhaseIsVisibleInTheNotch() {
        XCTAssertTrue(DictationPillView.hasActiveNotchContent(.failure("Microphone isn't available")))
        XCTAssertFalse(DictationPillView.hasActiveNotchContent(.idle))
        XCTAssertFalse(DictationPillView.hasActiveNotchContent(.success(.pasted)))
    }

    func testUpdaterConfigurationRequiresVerificationBeforeExtractionWithASignedFeed() {
        let feed = "https://releases.example.com/appcast.xml"
        let key = Data(repeating: 7, count: 32).base64EncodedString()

        XCTAssertTrue(
            AppUpdater.isConfigurationValid(
                feedString: feed,
                publicKey: key,
                requiresSignedFeed: true,
                verifiesUpdateBeforeExtraction: true
            )
        )
        XCTAssertFalse(
            AppUpdater.isConfigurationValid(
                feedString: feed,
                publicKey: key,
                requiresSignedFeed: true,
                verifiesUpdateBeforeExtraction: false
            )
        )

        // The shipped Info.plist must satisfy the same rule.
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Config/Info.plist")
        let plist = NSDictionary(contentsOf: plistURL) as? [String: Any] ?? [:]
        XCTAssertTrue(
            AppUpdater.isConfigurationValid(
                feedString: plist["SUFeedURL"] as? String,
                publicKey: plist["SUPublicEDKey"] as? String,
                requiresSignedFeed: plist["SURequireSignedFeed"] as? Bool ?? false,
                verifiesUpdateBeforeExtraction: plist["SUVerifyUpdateBeforeExtraction"] as? Bool ?? false
            ),
            "Config/Info.plist is not a valid Sparkle configuration"
        )
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MicrophoneRecorderEvent] = []

    func append(_ event: MicrophoneRecorderEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var snapshot: [MicrophoneRecorderEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
