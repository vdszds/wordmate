import AVFoundation
import Foundation
import os

struct AudioRecording: Sendable {
    let fileURL: URL
    let duration: TimeInterval
    /// False when the device did not stop in time and the file may not be
    /// fully written. The live transcription still holds the audio; the
    /// file must not be trusted as a fallback.
    let isComplete: Bool

    init(fileURL: URL, duration: TimeInterval, isComplete: Bool = true) {
        self.fileURL = fileURL
        self.duration = duration
        self.isComplete = isComplete
    }
}

/// Lifecycle events of one recording, delivered on the main actor.
enum MicrophoneRecorderEvent: Sendable, Equatable {
    /// The input device is running. `attempt` counts start attempts since the
    /// recording began; a value above one means an earlier attempt failed
    /// while the device was unavailable, for example a Bluetooth headset
    /// switching profiles.
    case started(device: String, sampleRate: Double, channels: Int, attempt: Int)
    /// The device delivered its first buffer, `latency` seconds after start.
    case firstBuffer(latency: TimeInterval)
    /// The device changed format mid-recording and capture was re-armed.
    case configurationChanged(sampleRate: Double, channels: Int)
    /// The engine was rebuilt after it stopped delivering audio.
    case recovered(rebuild: Int)
    /// The recording could not continue. The recorder has already torn
    /// itself down; the message is suitable for the user.
    case failed(String)
}

/// Records the microphone to a temporary CAF file and mirrors every buffer to
/// the live transcription pipeline.
///
/// All device work happens on a per-recording serial queue, never on the main
/// thread: starting a Bluetooth headset can take over a second and a wedged
/// device must never freeze the interface. A recording survives input format
/// changes by converting every buffer to the format chosen at start, retries a
/// start while the device is momentarily absent, rebuilds the engine when it
/// stops delivering audio, and reports every step through `onEvent`.
@MainActor
final class MicrophoneRecorder {
    typealias EventHandler = @MainActor (MicrophoneRecorderEvent) -> Void

    private var session: CaptureSession?
    private var outgoingSession: CaptureSession?

    /// Loads the capture stack once so the first recording after launch does
    /// not pay for device discovery and framework set-up. Nothing is started
    /// and the microphone indicator does not light up. Measured: the first
    /// recording in a process drops from about 230 ms to about 130 ms.
    static func prewarmCaptureStack() {
        guard SystemPermissions.microphone == .granted else { return }
        DispatchQueue.global(qos: .utility).async {
            guard let device = AVCaptureDevice.default(for: .audio),
                  let input = try? AVCaptureDeviceInput(device: device) else { return }
            let session = AVCaptureSession()
            session.beginConfiguration()
            if session.canAddInput(input) {
                session.addInput(input)
            }
            session.commitConfiguration()
            WordmateLog.audio.info("Capture stack pre-warmed for \(device.localizedName, privacy: .public)")
        }
    }

    func start(
        preferredDeviceUID: String? = nil,
        bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil,
        onEvent: @escaping EventHandler = { _ in }
    ) async throws {
        guard session == nil else {
            throw LocalTranscriberError.alreadyRecording
        }
        guard await SystemPermissions.requestMicrophone() else {
            throw LocalTranscriberError.microphonePermissionDenied
        }
        try startWhenAuthorized(
            preferredDeviceUID: preferredDeviceUID,
            bufferHandler: bufferHandler,
            onEvent: onEvent
        )
    }

    /// Begins a recording and returns immediately. The device starts on a
    /// background queue; progress and failures arrive through `onEvent`.
    func startWhenAuthorized(
        preferredDeviceUID: String? = nil,
        bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil,
        onEvent: @escaping EventHandler = { _ in }
    ) throws {
        guard SystemPermissions.microphone == .granted else {
            throw LocalTranscriberError.microphonePermissionDenied
        }
        guard session == nil else {
            throw LocalTranscriberError.alreadyRecording
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-transcriber-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        let session = CaptureSession(
            fileURL: fileURL,
            preferredDeviceUID: preferredDeviceUID,
            bufferHandler: bufferHandler,
            predecessor: outgoingSession
        )
        outgoingSession = nil
        session.onEvent = { [weak self, weak session] event in
            Task { @MainActor [weak self, weak session] in
                guard let self, let session, self.session === session else { return }
                if case .failed = event {
                    self.session = nil
                }
                onEvent(event)
            }
        }
        self.session = session
        session.begin()
    }

    /// Stops the device and returns the recording. Never blocks the main
    /// thread: if the device does not stop within a few seconds the session
    /// is abandoned and the audio captured so far is returned.
    func stop() async throws -> AudioRecording {
        guard let session else {
            throw LocalTranscriberError.notRecording
        }
        self.session = nil
        outgoingSession = session
        return await session.finish(timeout: 3)
    }

    /// Discards the recording. Teardown happens in the background and the
    /// temporary file is deleted afterwards.
    func abandon() {
        guard let session else { return }
        session.abandon()
        outgoingSession = session
        self.session = nil
    }

    func currentLevel() -> Double {
        session?.currentLevel ?? 0
    }

    /// Whether the input device has delivered at least one buffer.
    var hasReceivedAudio: Bool {
        session?.hasReceivedAudio ?? false
    }

    /// Whether any delivered buffer contained more than silence. A Bluetooth
    /// headset delivers silence while it switches profiles.
    var hasReceivedSignal: Bool {
        session?.hasReceivedSignal ?? false
    }

    /// Whether any delivered sample was non-zero. A real microphone always
    /// carries noise; an all-zero stream is a muted or dead input.
    var hasReceivedNonZeroAudio: Bool {
        session?.hasReceivedNonZeroAudio ?? false
    }

    var secondsSinceFirstBuffer: TimeInterval? {
        session?.secondsSinceFirstBuffer
    }
}

/// One recording's capture pipeline, built on `AVCaptureSession`.
///
/// `AVCaptureSession` opens only the input device (no aggregate with the
/// output device, so it starts in tens of milliseconds), follows the device
/// through profile and sample-rate changes on its own, and delivers audio
/// already converted to the fixed capture format. Every remaining failure
/// mode is covered by retrying the start while a device is absent, rebuilding
/// the session when audio stops arriving, and reporting each step.
private final class CaptureSession: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Parakeet's native input format. Capturing at 16 kHz mono means no
    /// later resampling and a consistent format whatever the device does.
    static let captureFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioSampleLoader.sampleRate,
        channels: 1,
        interleaved: false
    )!

    private static let maximumStartAttempts = 10
    private static let retryDelay: TimeInterval = 0.3
    private static let maximumRebuilds = 4
    private static let startTimeout: TimeInterval = 5
    private static let predecessorTeardownWait: TimeInterval = 0.5
    private static let firstBufferTimeout: TimeInterval = 4
    private static let stallTimeout: TimeInterval = 1.5
    private static let digitalSilenceTimeout: TimeInterval = 4
    private static let watchdogInterval: TimeInterval = 0.5
    private static let signalThreshold: Float = 0.0005

    private let queue = DispatchQueue(
        label: "sh.wordmate.capture." + UUID().uuidString,
        qos: .userInteractive
    )
    private let audioQueue = DispatchQueue(
        label: "sh.wordmate.capture.audio." + UUID().uuidString,
        qos: .userInteractive
    )
    private let fileURL: URL
    private let preferredDeviceUID: String?
    private let bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private let predecessor: CaptureSession?
    /// Entered when the session begins and left once its teardown has run,
    /// so the next session can wait briefly before opening the device.
    private let teardownGroup = DispatchGroup()
    var onEvent: (@Sendable (MicrophoneRecorderEvent) -> Void)?

    private let lock = NSLock()
    // Guarded by `lock`; read from the audio queue and the main actor.
    private var abandoned = false
    private var finished = false
    private var sink: AudioRecordingSink?
    private var firstBufferAt: Date?
    private var signalDetected = false
    private var nonZeroDetected = false
    private var startToken = 0
    private var startCompleted = false
    private var teardownLeft = false

    // Confined to `queue`.
    private let startedAt = Date()
    private var session: AVCaptureSession?
    private var observers: [NSObjectProtocol] = []
    private var attempt = 0
    private var rebuilds = 0
    private var running = false
    private var framesAtSessionStart: AVAudioFramePosition = 0
    private var lastProgressFrames: AVAudioFramePosition = 0
    private var lastProgressAt = Date()

    init(
        fileURL: URL,
        preferredDeviceUID: String?,
        bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?,
        predecessor: CaptureSession? = nil
    ) {
        self.fileURL = fileURL
        self.preferredDeviceUID = preferredDeviceUID
        self.bufferHandler = bufferHandler
        self.predecessor = predecessor
    }

    // MARK: State read from other threads

    var currentLevel: Double {
        lock.lock()
        defer { lock.unlock() }
        return sink?.currentLevel ?? 0
    }

    var hasReceivedAudio: Bool {
        lock.lock()
        defer { lock.unlock() }
        return firstBufferAt != nil
    }

    var hasReceivedSignal: Bool {
        lock.lock()
        defer { lock.unlock() }
        return signalDetected
    }

    var hasReceivedNonZeroAudio: Bool {
        lock.lock()
        defer { lock.unlock() }
        return nonZeroDetected
    }

    var secondsSinceFirstBuffer: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return firstBufferAt.map { Date().timeIntervalSince($0) }
    }

    private var currentDuration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return sink?.duration ?? 0
    }

    private var isAlive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !abandoned && !finished
    }

    // MARK: Lifecycle

    func begin() {
        teardownGroup.enter()
        queue.async {
            // Let the previous recording release the device first, briefly,
            // so a quick discard-and-restart does not flap a Bluetooth
            // headset between profiles. A wedged predecessor is not waited on.
            if let predecessor = self.predecessor {
                _ = predecessor.teardownGroup.wait(timeout: .now() + Self.predecessorTeardownWait)
            }
            self.attemptStart()
        }
    }

    func abandon() {
        lock.lock()
        abandoned = true
        lock.unlock()
        queue.async {
            self.tearDown()
            self.releaseSink()
            try? FileManager.default.removeItem(at: self.fileURL)
        }
    }

    func finish(timeout: TimeInterval) async -> AudioRecording {
        await withCheckedContinuation { continuation in
            let resumed = OnceFlag()
            queue.async {
                self.lock.lock()
                self.finished = true
                self.lock.unlock()
                self.tearDown()
                let duration = self.currentDuration
                self.releaseSink()
                if resumed.claim() {
                    continuation.resume(
                        returning: AudioRecording(fileURL: self.fileURL, duration: duration)
                    )
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                guard resumed.claim() else { return }
                WordmateLog.audio.error(
                    "Microphone stop timed out after \(timeout, privacy: .public) s; abandoning the session"
                )
                self.lock.lock()
                self.abandoned = true
                self.lock.unlock()
                continuation.resume(
                    returning: AudioRecording(
                        fileURL: self.fileURL,
                        duration: self.currentDuration,
                        isComplete: false
                    )
                )
            }
        }
    }

    // MARK: Starting

    private func attemptStart() {
        guard isAlive else { return }
        attempt += 1

        guard let device = Self.captureDevice(preferredUID: preferredDeviceUID) else {
            retryOrFail(reason: "no microphone available")
            return
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            retryOrFail(reason: "\(device.localizedName) could not be opened: \(error.localizedDescription)")
            return
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            retryOrFail(reason: "\(device.localizedName) rejected by the capture session")
            return
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.captureFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: audioQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            retryOrFail(reason: "audio output rejected by the capture session")
            return
        }
        session.addOutput(output)
        session.commitConfiguration()

        if ensureSink() == false {
            fail("The recording file could not be created.")
            return
        }

        // Starting the device is synchronous and can take over a second for
        // a Bluetooth headset. This runs on the session queue, never on main.
        // A device that never returns would leave the queue wedged, so a
        // timeout armed on another queue fails the recording visibly.
        armStartTimeout(deviceName: device.localizedName)
        session.startRunning()
        markStartCompleted()
        guard session.isRunning else {
            retryOrFail(reason: "\(device.localizedName) did not start")
            return
        }

        self.session = session
        running = true
        lock.lock()
        framesAtSessionStart = sink?.receivedFrames ?? 0
        lock.unlock()
        lastProgressFrames = framesAtSessionStart
        lastProgressAt = Date()

        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: session,
                queue: nil
            ) { [weak self] notification in
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                self?.queue.async {
                    self?.rebuild(
                        reason: "capture runtime error: \(error?.localizedDescription ?? "unknown")",
                        delay: 0
                    )
                }
            },
            center.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: device,
                queue: nil
            ) { [weak self] _ in
                self?.queue.async {
                    self?.rebuild(reason: "microphone disconnected", delay: Self.retryDelay)
                }
            },
        ]

        WordmateLog.audio.info(
            "Microphone started: \(device.localizedName, privacy: .public) (\(device.uniqueID, privacy: .public)), attempt \(self.attempt, privacy: .public), rebuild \(self.rebuilds, privacy: .public)"
        )
        if rebuilds > 0 {
            onEvent?(.recovered(rebuild: rebuilds))
        } else {
            onEvent?(
                .started(
                    device: device.localizedName,
                    sampleRate: Self.captureFormat.sampleRate,
                    channels: 1,
                    attempt: attempt
                )
            )
        }
        scheduleWatchdog(for: session)
    }

    /// The saved microphone when it is connected, otherwise the system
    /// default. `AVCaptureDevice` unique IDs are the Core Audio device UIDs
    /// the microphone menu stores.
    private static func captureDevice(preferredUID: String?) -> AVCaptureDevice? {
        if let preferredUID,
           let preferred = AVCaptureDevice(uniqueID: preferredUID),
           preferred.isConnected,
           preferred.hasMediaType(.audio) {
            return preferred
        }
        return AVCaptureDevice.default(for: .audio)
    }

    private func ensureSink() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if sink != nil { return true }
        do {
            let file = try AVAudioFile(forWriting: fileURL, settings: Self.captureFormat.settings)
            sink = AudioRecordingSink(
                file: file,
                format: Self.captureFormat,
                bufferHandler: bufferHandler
            )
            return true
        } catch {
            WordmateLog.audio.error("Recording file could not be created: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func armStartTimeout(deviceName: String) {
        lock.lock()
        startToken += 1
        let token = startToken
        startCompleted = false
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.startTimeout) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillStarting = !self.startCompleted && self.startToken == token && !self.abandoned && !self.finished
            if stillStarting {
                self.abandoned = true
            }
            self.lock.unlock()
            guard stillStarting else { return }
            WordmateLog.audio.error(
                "Microphone \(deviceName, privacy: .public) did not start within \(Self.startTimeout, privacy: .public) s; abandoning the session"
            )
            self.onEvent?(.failed("The microphone is taking too long to start. Check the device and try again."))
            // The session queue may be blocked inside startRunning(); the
            // teardown runs there once it returns, guarded by `abandoned`.
            self.queue.async {
                self.tearDown()
                self.releaseSink()
                try? FileManager.default.removeItem(at: self.fileURL)
            }
        }
    }

    private func markStartCompleted() {
        lock.lock()
        startCompleted = true
        lock.unlock()
    }

    private func retryOrFail(reason: String) {
        guard isAlive else { return }
        if attempt < Self.maximumStartAttempts {
            WordmateLog.audio.info(
                "Microphone start attempt \(self.attempt, privacy: .public) failed (\(reason, privacy: .public)); retrying"
            )
            queue.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
                self?.attemptStart()
            }
        } else {
            WordmateLog.audio.error(
                "Microphone start gave up after \(self.attempt, privacy: .public) attempts (\(reason, privacy: .public))"
            )
            fail("The microphone isn't available. Check that it is connected and selected, then try again.")
        }
    }

    /// Rebuilds capture when the device stops delivering buffers: four
    /// seconds for the first buffer (a Bluetooth headset can take that long
    /// to switch profiles), then 1.5 seconds of silence from a device that
    /// was already streaming. This catches every failure mode that leaves a
    /// session "running" without audio, whatever its cause.
    private func scheduleWatchdog(for session: AVCaptureSession) {
        queue.asyncAfter(deadline: .now() + Self.watchdogInterval) { [weak self] in
            guard let self, self.isAlive, self.running, self.session === session else { return }
            self.lock.lock()
            let frames = self.sink?.receivedFrames ?? 0
            self.lock.unlock()

            self.lock.lock()
            let nonZero = self.nonZeroDetected
            self.lock.unlock()
            if frames != self.lastProgressFrames, !nonZero,
               Date().timeIntervalSince(self.lastProgressAt) >= Self.digitalSilenceTimeout,
               frames != self.framesAtSessionStart {
                // Buffers arrive but every sample is exactly zero: a muted or
                // dead input, not a quiet room.
                self.rebuild(reason: "digital silence for \(Self.digitalSilenceTimeout) s", delay: 0)
                return
            }
            if frames != self.lastProgressFrames {
                self.lastProgressFrames = frames
                if nonZero || frames == self.framesAtSessionStart {
                    self.lastProgressAt = Date()
                }
            } else {
                let stalledFor = Date().timeIntervalSince(self.lastProgressAt)
                let waitingForFirstBuffer = frames == self.framesAtSessionStart
                let limit = waitingForFirstBuffer ? Self.firstBufferTimeout : Self.stallTimeout
                if stalledFor >= limit {
                    self.rebuild(
                        reason: waitingForFirstBuffer
                            ? "no audio within \(Self.firstBufferTimeout) s"
                            : "audio stalled for \(Self.stallTimeout) s",
                        delay: 0
                    )
                    return
                }
            }
            self.scheduleWatchdog(for: session)
        }
    }

    // MARK: Recovery

    private func rebuild(reason: String, delay: TimeInterval) {
        guard isAlive, running else { return }
        tearDown()
        rebuilds += 1
        let silenceRebuilds = reason.hasPrefix("digital silence")
        guard rebuilds <= Self.maximumRebuilds, !(silenceRebuilds && rebuilds > 1) else {
            WordmateLog.audio.error(
                "Microphone gave up after \(self.rebuilds, privacy: .public) rebuilds (\(reason, privacy: .public))"
            )
            fail(
                silenceRebuilds
                    ? "The microphone is delivering only silence. Check that it isn't muted."
                    : "The microphone stopped delivering audio. Check the device and try again."
            )
            return
        }
        WordmateLog.audio.info("Rebuilding microphone capture (\(reason, privacy: .public))")
        attempt = 0
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.attemptStart()
        }
    }

    private func fail(_ message: String) {
        lock.lock()
        abandoned = true
        lock.unlock()
        tearDown()
        releaseSink()
        try? FileManager.default.removeItem(at: fileURL)
        onEvent?(.failed(message))
    }

    // MARK: Audio delivery (audio queue)

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        lock.lock()
        let alive = !abandoned && !finished
        let sink = self.sink
        lock.unlock()
        guard alive, let sink, let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }

        lock.lock()
        let isFirstBuffer = firstBufferAt == nil
        if isFirstBuffer {
            firstBufferAt = Date()
        }
        lock.unlock()

        let peak = sink.receive(buffer)
        if peak > 0 {
            lock.lock()
            nonZeroDetected = true
            if peak > Self.signalThreshold {
                signalDetected = true
            }
            lock.unlock()
        }
        if isFirstBuffer {
            let latency = Date().timeIntervalSince(startedAt)
            WordmateLog.audio.info("First microphone buffer after \(latency, privacy: .public) s")
            onEvent?(.firstBuffer(latency: latency))
        }
    }

    /// Copies a 16 kHz mono float sample buffer into a PCM buffer of the
    /// capture format.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              streamDescription.mSampleRate == captureFormat.sampleRate,
              streamDescription.mChannelsPerFrame == 1,
              streamDescription.mBitsPerChannel == 32,
              streamDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            return nil
        }

        var blockBuffer: CMBlockBuffer?
        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
        )
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &bufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr,
              let source = bufferList.mBuffers.mData,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: captureFormat,
                  frameCapacity: AVAudioFrameCount(frameCount)
              ),
              let destination = buffer.floatChannelData?[0] else {
            return nil
        }
        let availableFrames = min(frameCount, Int(bufferList.mBuffers.mDataByteSize) / MemoryLayout<Float>.size)
        destination.update(
            from: source.assumingMemoryBound(to: Float.self),
            count: availableFrames
        )
        buffer.frameLength = AVAudioFrameCount(availableFrames)
        // `blockBuffer` keeps the sample memory alive until here.
        withExtendedLifetime(blockBuffer) {}
        return buffer
    }

    // MARK: Teardown

    private func tearDown() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        if let session {
            if session.isRunning {
                session.stopRunning()
            }
            self.session = nil
        }
        running = false

        lock.lock()
        let shouldLeave = !teardownLeft
        teardownLeft = true
        lock.unlock()
        if shouldLeave {
            teardownGroup.leave()
        }
    }

    private func releaseSink() {
        // Dropping the sink closes the file and flushes pending writes.
        lock.lock()
        sink = nil
        lock.unlock()
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

private final class AudioRecordingSink: @unchecked Sendable {
    let format: AVAudioFormat

    private let file: AVAudioFile
    private let bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private let stateLock = NSLock()
    private var level = 0.0
    private var frames: AVAudioFramePosition = 0

    init(
        file: AVAudioFile,
        format: AVAudioFormat,
        bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    ) {
        self.file = file
        self.format = format
        self.bufferHandler = bufferHandler
    }

    var currentLevel: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        return level
    }

    var receivedFrames: AVAudioFramePosition {
        stateLock.lock()
        defer { stateLock.unlock() }
        return frames
    }

    var duration: TimeInterval {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard format.sampleRate > 0 else { return 0 }
        return TimeInterval(frames) / format.sampleRate
    }

    /// Writes the buffer, forwards it, and returns its peak absolute sample.
    @discardableResult
    func receive(_ buffer: AVAudioPCMBuffer) -> Float {
        try? file.write(from: buffer)

        stateLock.lock()
        frames += AVAudioFramePosition(buffer.frameLength)
        stateLock.unlock()

        bufferHandler?(buffer)

        guard let channels = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return 0 }

        var sumOfSquares = 0.0
        var peak: Float = 0
        for channelIndex in 0..<channelCount {
            let samples = channels[channelIndex]
            for frameIndex in 0..<frameCount {
                let sample = samples[frameIndex]
                sumOfSquares += Double(sample * sample)
                peak = max(peak, abs(sample))
            }
        }

        let rms = sqrt(sumOfSquares / Double(frameCount * channelCount))
        let decibels = rms > 0 ? 20 * log10(rms) : -80
        let normalizedLevel = AudioLevelNormalizer.normalize(decibels: decibels)

        stateLock.lock()
        level = normalizedLevel
        stateLock.unlock()
        return peak
    }
}
