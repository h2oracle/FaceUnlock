import Foundation

/// Tracks failed face-unlock attempts within one screen-lock session.
/// After `maximumFailures` failures, or `maximumAttempts` attempts of any
/// kind, nothing more is tried until the session ends (the user unlocks
/// manually), which calls `startNewLockSession()`.
public struct AttemptLockout: Equatable, Sendable {
    public static let defaultMaximumFailures = 3
    public static let defaultMaximumAttempts = 5

    public let maximumFailures: Int
    /// Hard cap on attempts started per lock session, failed or not.
    public let maximumAttempts: Int
    public private(set) var failures = 0
    public private(set) var attemptsStarted = 0
    /// Set when a typed password did not unlock the screen. Locks out
    /// immediately: retyping a wrong password could trip account lockout.
    public private(set) var passwordRejected = false

    public init(maximumFailures: Int = AttemptLockout.defaultMaximumFailures,
                maximumAttempts: Int = AttemptLockout.defaultMaximumAttempts) {
        self.maximumFailures = max(1, maximumFailures)
        self.maximumAttempts = max(1, maximumAttempts)
    }

    /// Blocks typing a password (checked again right before unlocking).
    public var isLockedOut: Bool { passwordRejected || failures >= maximumFailures }
    /// Blocks starting another attempt.
    public var canStartAttempt: Bool { !isLockedOut && attemptsStarted < maximumAttempts }
    public var remainingAttempts: Int {
        canStartAttempt ? min(maximumFailures - failures, maximumAttempts - attemptsStarted) : 0
    }

    public mutating func recordAttemptStarted() {
        attemptsStarted += 1
    }

    public mutating func recordFailure() {
        failures += 1
    }

    public mutating func recordPasswordRejected() {
        passwordRejected = true
    }

    public mutating func startNewLockSession() {
        failures = 0
        attemptsStarted = 0
        passwordRejected = false
    }
}
