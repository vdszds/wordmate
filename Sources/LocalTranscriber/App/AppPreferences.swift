import Foundation

@MainActor
final class AppPreferences {
    private enum Key {
        static let completedOnboarding = "completedOnboarding"
        static let disabledSystemFnShortcut = "disabledSystemFnShortcut"
        static let selectedInputDeviceUID = "selectedInputDeviceUID"
        static let selectedInputDeviceName = "selectedInputDeviceName"
        static let postProcessingEnabled = "postProcessingEnabled"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Key.completedOnboarding) }
        set { defaults.set(newValue, forKey: Key.completedOnboarding) }
    }

    var hasDisabledSystemFnShortcut: Bool {
        get { defaults.bool(forKey: Key.disabledSystemFnShortcut) }
        set { defaults.set(newValue, forKey: Key.disabledSystemFnShortcut) }
    }

    var selectedInputDeviceUID: String? {
        get { defaults.string(forKey: Key.selectedInputDeviceUID) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.selectedInputDeviceUID)
            } else {
                defaults.removeObject(forKey: Key.selectedInputDeviceUID)
            }
        }
    }

    var selectedInputDeviceName: String? {
        get { defaults.string(forKey: Key.selectedInputDeviceName) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.selectedInputDeviceName)
            } else {
                defaults.removeObject(forKey: Key.selectedInputDeviceName)
            }
        }
    }

    var postProcessingEnabled: Bool {
        get { defaults.bool(forKey: Key.postProcessingEnabled) }
        set { defaults.set(newValue, forKey: Key.postProcessingEnabled) }
    }

}
