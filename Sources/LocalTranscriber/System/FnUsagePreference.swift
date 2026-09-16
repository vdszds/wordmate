import AppKit
import Foundation

/// The system-wide "Press 🌐 key to" setting (`AppleFnUsageType` in
/// `com.apple.HIToolbox`). While it is anything but "Do Nothing", macOS reacts
/// to bare Fn presses (input source switcher, emoji palette, dictation) below
/// the event-tap layer, so FnShortcutMonitor cannot suppress it by swallowing
/// events.
enum FnUsagePreference {
    private static let domain = "com.apple.HIToolbox" as CFString
    private static let key = "AppleFnUsageType" as CFString

    static var isSystemShortcutDisabled: Bool {
        // CFPreferencesCopyAppValue serves a per-process cache and misses edits
        // made in System Settings; synchronizing and reading with explicit
        // user/host fetches the live value from cfprefsd. A missing key means
        // the system default, which still switches input sources.
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let value = CFPreferencesCopyValue(
            key,
            domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? Int
        return value == 0
    }

    @discardableResult
    static func disableSystemShortcut() -> Bool {
        CFPreferencesSetValue(
            key,
            0 as CFNumber,
            domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        applyLive(0)
        return isSystemShortcutDisabled
    }

    /// System Settings applies this preference immediately by calling the
    /// private Carbon function `TISUpdateFnUsageType()`, which broadcasts the
    /// change so every process drops its cached Fn role. Without the call the
    /// new value only takes effect after logging out and back in.
    private static func applyLive(_ value: Int32) {
        typealias UpdateFn = @convention(c) (Int32) -> Void
        guard
            let carbon = dlopen("/System/Library/Frameworks/Carbon.framework/Carbon", RTLD_NOW),
            let symbol = dlsym(carbon, "TISUpdateFnUsageType")
        else { return }
        unsafeBitCast(symbol, to: UpdateFn.self)(value)
    }

    @MainActor
    static func openKeyboardSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
