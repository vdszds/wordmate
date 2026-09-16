import CoreGraphics
import Foundation

enum FnKeyTransition: Equatable {
    case pressed(timestamp: TimeInterval)
    case released(timestamp: TimeInterval)
}

enum DictationShortcutEvent: Equatable {
    case fn(FnKeyTransition)
    case discardContinuousRecording
}

struct FnKeyTransitionDetector {
    private(set) var wasPressed = false

    mutating func handle(
        isPressed: Bool,
        timestamp: TimeInterval
    ) -> FnKeyTransition? {
        guard isPressed != wasPressed else { return nil }
        wasPressed = isPressed
        return isPressed
            ? .pressed(timestamp: timestamp)
            : .released(timestamp: timestamp)
    }
}

struct EscapeKeyCaptureDecision: Equatable {
    let shouldConsume: Bool
    let shouldDiscard: Bool
}

struct EscapeKeyCaptureDetector {
    private(set) var isCapturingPress = false

    mutating func handle(
        isPressed: Bool,
        captureEnabled: Bool,
        isRepeat: Bool = false
    ) -> EscapeKeyCaptureDecision {
        if isPressed {
            let shouldConsume = captureEnabled || isCapturingPress
            let shouldDiscard = captureEnabled && !isCapturingPress && !isRepeat
            if shouldConsume {
                isCapturingPress = true
            }
            return EscapeKeyCaptureDecision(
                shouldConsume: shouldConsume,
                shouldDiscard: shouldDiscard
            )
        }

        let shouldConsume = isCapturingPress
        isCapturingPress = false
        return EscapeKeyCaptureDecision(
            shouldConsume: shouldConsume,
            shouldDiscard: false
        )
    }
}

@MainActor
final class FnShortcutMonitor {
    private var worker: FnEventTapWorker?
    private var escapeCaptureEnabled = false

    func start(
        handler: @escaping @MainActor (DictationShortcutEvent) -> Void
    ) {
        stop()
        let worker = FnEventTapWorker { event in
            Task { @MainActor in
                handler(event)
            }
        }
        worker.setEscapeCaptureEnabled(escapeCaptureEnabled)
        self.worker = worker
        worker.start()
    }

    func setEscapeCaptureEnabled(_ enabled: Bool) {
        escapeCaptureEnabled = enabled
        worker?.setEscapeCaptureEnabled(enabled)
    }

    /// Forgets a press whose release event never arrived, so the next
    /// physical press is reported again instead of being taken for a repeat.
    func resetPressedState() {
        worker?.resetPressedState()
    }

    func stop() {
        worker?.stop()
        worker = nil
    }
}

private final class FnEventTapWorker: @unchecked Sendable {
    private static let fnKeyCode: Int64 = 63
    private static let escapeKeyCode: Int64 = 53

    private let stateLock = NSLock()
    private let handler: (DictationShortcutEvent) -> Void
    private var detector = FnKeyTransitionDetector()
    private var escapeDetector = EscapeKeyCaptureDetector()
    private var escapeCaptureEnabled = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var shouldStop = false

    init(handler: @escaping (DictationShortcutEvent) -> Void) {
        self.handler = handler
    }

    func setEscapeCaptureEnabled(_ enabled: Bool) {
        stateLock.lock()
        escapeCaptureEnabled = enabled
        stateLock.unlock()
    }

    func resetPressedState() {
        stateLock.lock()
        detector = FnKeyTransitionDetector()
        stateLock.unlock()
    }

    func start() {
        stateLock.lock()
        shouldStop = false
        let thread = Thread { self.runEventTap() }
        thread.name = "Wordmate Fn Event Tap"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        stateLock.unlock()
        thread.start()
    }

    func stop() {
        stateLock.lock()
        shouldStop = true
        let eventTap = eventTap
        let runLoop = runLoop
        stateLock.unlock()

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }
    }

    private func runEventTap() {
        let eventMask = [
            CGEventType.keyDown,
            CGEventType.keyUp,
            CGEventType.flagsChanged,
        ].reduce(CGEventMask(0)) { mask, type in
            mask | (CGEventMask(1) << type.rawValue)
        }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: fnEventTapCallback,
            userInfo: userInfo
        ) else {
            finishThread()
            return
        }

        guard let runLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            eventTap,
            0
        ) else {
            CFMachPortInvalidate(eventTap)
            finishThread()
            return
        }

        let runLoop = CFRunLoopGetCurrent()
        stateLock.lock()
        let stopBeforeStarting = shouldStop
        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
        self.runLoop = runLoop
        stateLock.unlock()

        guard !stopBeforeStarting else {
            CFMachPortInvalidate(eventTap)
            finishThread()
            return
        }

        CFRunLoopAddSource(runLoop, runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        CFRunLoopRun()

        CGEvent.tapEnable(tap: eventTap, enable: false)
        CFRunLoopRemoveSource(runLoop, runLoopSource, .commonModes)
        CFMachPortInvalidate(eventTap)
        finishThread()
    }

    private func finishThread() {
        stateLock.lock()
        eventTap = nil
        runLoopSource = nil
        runLoop = nil
        thread = nil
        stateLock.unlock()
    }

    fileprivate func processTapEvent(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stateLock.lock()
            let eventTap = eventTap
            let shouldStop = shouldStop
            stateLock.unlock()
            if let eventTap, !shouldStop {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == Self.escapeKeyCode {
            return processEscapeEvent(type: type, event: event)
        }

        guard keyCode == Self.fnKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        let isPressed: Bool
        switch type {
        case .flagsChanged:
            isPressed = event.flags.contains(.maskSecondaryFn)
        case .keyDown:
            isPressed = true
        case .keyUp:
            isPressed = false
        default:
            return Unmanaged.passUnretained(event)
        }

        let timestamp = TimeInterval(event.timestamp) / 1_000_000_000
        stateLock.lock()
        let transition = detector.handle(
            isPressed: isPressed,
            timestamp: timestamp
        )
        stateLock.unlock()
        if let transition {
            handler(.fn(transition))
        }

        // Delete the Fn event immediately. Recording work is dispatched to the
        // main actor and never blocks this time-sensitive callback.
        return nil
    }

    private func processEscapeEvent(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        let isPressed: Bool
        switch type {
        case .keyDown:
            isPressed = true
        case .keyUp:
            isPressed = false
        default:
            return Unmanaged.passUnretained(event)
        }

        stateLock.lock()
        let captureEnabled = escapeCaptureEnabled
        stateLock.unlock()

        let decision = escapeDetector.handle(
            isPressed: isPressed,
            captureEnabled: captureEnabled,
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        )
        if decision.shouldDiscard {
            handler(.discardContinuousRecording)
        }

        return decision.shouldConsume ? nil : Unmanaged.passUnretained(event)
    }
}

private let fnEventTapCallback: CGEventTapCallBack = {
    _, type, event, userInfo in
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let monitor = Unmanaged<FnEventTapWorker>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    return monitor.processTapEvent(type: type, event: event)
}
