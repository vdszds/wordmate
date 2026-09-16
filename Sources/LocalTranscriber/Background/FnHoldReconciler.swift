import Foundation

/// Detects a lost Fn release. The event tap swallows Fn transitions, and if
/// macOS drops the release event the app would believe Fn is still held and
/// keep recording. While a hold is in progress the controller feeds the
/// hardware modifier state here; once the key has been seen physically
/// pressed at least once, a sustained "not pressed" reading is treated as the
/// missing release. Nothing is synthesized on systems where the hardware
/// state never reports the Fn flag.
struct FnHoldReconciler: Equatable {
    static let releaseGrace: TimeInterval = 0.6

    private(set) var observedPhysicalPress = false
    private var releasedSince: TimeInterval?

    /// Returns true when the hold should be ended as if Fn were released.
    mutating func observe(fnPhysicallyPressed: Bool, at time: TimeInterval) -> Bool {
        if fnPhysicallyPressed {
            observedPhysicalPress = true
            releasedSince = nil
            return false
        }
        guard observedPhysicalPress else { return false }
        guard let releasedSince else {
            self.releasedSince = time
            return false
        }
        return time - releasedSince >= Self.releaseGrace
    }

    mutating func reset() {
        observedPhysicalPress = false
        releasedSince = nil
    }
}
