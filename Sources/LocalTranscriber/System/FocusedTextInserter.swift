import ApplicationServices
import AppKit
import Foundation

enum TextInsertionResult: Equatable, Sendable {
    case pasted
    case copiedToClipboard

    var message: String {
        switch self {
        case .pasted:
            return "Pasted"
        case .copiedToClipboard:
            return "Copied"
        }
    }
}

@MainActor
final class FocusedTextInserter {
    func insert(_ text: String, targetPID: pid_t?) async throws -> TextInsertionResult {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw LocalTranscriberError.clipboardWriteFailed
        }

        guard SystemPermissions.accessibilityGranted,
              let targetPID,
              targetPID != ProcessInfo.processInfo.processIdentifier,
              let targetApplication = NSRunningApplication(
                processIdentifier: targetPID
              ) else {
            return .copiedToClipboard
        }

        if NSWorkspace.shared.frontmostApplication?.processIdentifier != targetPID {
            targetApplication.activate(options: [.activateAllWindows])

            for _ in 0..<6 {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID {
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
            return .copiedToClipboard
        }

        // Give the target app a moment to restore its focused control after
        // activation, then issue the same paste command a user would.
        try? await Task.sleep(for: .milliseconds(80))

        guard let eventSource = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                keyboardEventSource: eventSource,
                virtualKey: 9,
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: eventSource,
                virtualKey: 9,
                keyDown: false
              ) else {
            throw LocalTranscriberError.pasteEventFailed
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return .pasted
    }
}
