import Foundation

/// Limits face-unlock tries within one screen-lock session.
///
/// - A *failure* is a "failed look": a single face in view that doesn't
///   match for a sustained period (frames with no face never count).
/// - After `maximumFailures` failures, scanning stops until the display has
///   gone to sleep and woken again (`displayWoke()`); input doesn't resume it.
/// - After `maximumTotalFailures` failures in the whole lock session, or one
///   typed password that didn't unlock, nothing more is tried until the user
///   unlocks manually (`startNewLockSession()`). The same applies once a
///   face has been in front of the camera for `maximumFaceSeconds` in total
///   during the lock session, so trying over and over can't go on forever.
public struct AttemptLockout: Equatable, Sendable {
    public static let defaultMaximumFailures = 3
    public static let defaultMaximumTotalFailures = 5
    public static let defaultMaximumFaceSeconds: TimeInterval = 120

    public let maximumFailures: Int
    public let maximumTotalFailures: Int
    public let maximumFaceSeconds: TimeInterval
    /// Seconds a face was in view during this lock session.
    public private(set) var faceSeconds: TimeInterval = 0
    /// Failures since the last display wake.
    public private(set) var failures = 0
    /// Failures in this lock session.
    public private(set) var totalFailures = 0
    /// Set when a typed password did not unlock the screen (or couldn't be
    /// typed). Retyping a wrong password could trip account lockout.
    public private(set) var passwordRejected = false

    public init(maximumFailures: Int = AttemptLockout.defaultMaximumFailures,
                maximumTotalFailures: Int = AttemptLockout.defaultMaximumTotalFailures,
                maximumFaceSeconds: TimeInterval = AttemptLockout.defaultMaximumFaceSeconds) {
        self.maximumFailures = max(1, maximumFailures)
        self.maximumTotalFailures = max(self.maximumFailures, maximumTotalFailures)
        self.maximumFaceSeconds = max(1, maximumFaceSeconds)
    }

    public var faceTimeExhausted: Bool { faceSeconds >= maximumFaceSeconds }

    public mutating func recordFaceTime(_ seconds: TimeInterval) {
        guard seconds > 0, seconds.isFinite else { return }
        faceSeconds += seconds
    }

    /// Stopped until the user unlocks manually.
    public var isLockedOut: Bool {
        passwordRejected || totalFailures >= maximumTotalFailures || faceTimeExhausted
    }
    /// Stopped until the display sleeps and wakes.
    public var needsDisplayWake: Bool { failures >= maximumFailures }
    public var canScan: Bool { !isLockedOut && !needsDisplayWake }
    public var remainingBeforePause: Int { canScan ? min(maximumFailures - failures, maximumTotalFailures - totalFailures) : 0 }

    public mutating func recordFailure() {
        failures += 1
        totalFailures += 1
    }

    public mutating func recordPasswordRejected() {
        passwordRejected = true
    }

    /// The display went to sleep and woke again: a fresh set of looks.
    public mutating func displayWoke() {
        failures = 0
    }

    public mutating func startNewLockSession() {
        failures = 0
        totalFailures = 0
        faceSeconds = 0
        passwordRejected = false
    }
}
