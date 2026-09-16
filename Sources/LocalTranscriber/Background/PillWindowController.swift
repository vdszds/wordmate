import AppKit
import Combine
import SwiftUI

@MainActor
final class PillWindowController {
    private let panel: OverlayPanel
    private var phaseSubscription: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var isEnabled = false
    private var currentPhase: DictationController.Phase = .idle

    init(controller: DictationController) {
        panel = OverlayPanel(
            contentRect: NSRect(
                origin: .zero,
                size: DictationPillView.windowSize
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        let hostingView = NSHostingView(
            rootView: DictationPillView(controller: controller)
                .background(Color.clear)
        )
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false
        panel.contentView = hostingView

        phaseSubscription = controller.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                self?.currentPhase = phase
                self?.updatePanel(for: phase)
            }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.positionPanel() }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    func show() {
        isEnabled = true
        positionPanel()
        updatePanel(for: currentPhase)
    }

    func hide() {
        isEnabled = false
        panel.orderOut(nil)
    }

    func close() {
        isEnabled = false
        panel.orderOut(nil)
        panel.close()
    }

    private func updatePanel(for phase: DictationController.Phase) {
        panel.ignoresMouseEvents = phase != .recording(.continuous)

        guard isEnabled else {
            panel.orderOut(nil)
            return
        }

        positionPanel()
        panel.orderFrontRegardless()
    }

    private func positionPanel() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let screenFrame = screen.frame
        let x = screenFrame.maxX - panel.frame.width
        let notchCenterY = screenFrame.maxY
            - (screenFrame.height / 3)
            + (screenFrame.height / 10)
        let y = notchCenterY - (panel.frame.height / 2)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
