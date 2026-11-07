import Foundation

/// Kept in the Keychain next to the password: what the template file and
/// the match threshold are supposed to be. A same-user process can edit
/// files in ~/Library or `defaults`, but can't silently rewrite this item
/// (it would need to delete and re-create it, which then fails the
/// prompt-free read). If either doesn't match, face unlock refuses to run.
public struct IntegrityRecord: Codable, Equatable, Sendable {
    public var templateSHA256: String?
    public var threshold: Float
    /// nil in records written before the setting existed; such records were
    /// made when blink + movement was the only behaviour.
    public var livenessMode: LivenessMode?
    /// Whether face unlock is switched on. nil in older records, which
    /// counts as off: turning it on again needs the login password.
    public var enabled: Bool?

    public init(templateSHA256: String?, threshold: Float, livenessMode: LivenessMode, enabled: Bool = false) {
        self.templateSHA256 = templateSHA256
        self.threshold = threshold
        self.livenessMode = livenessMode
        self.enabled = enabled
    }

    /// Face unlock only runs when both the preference and this record say on.
    public func isEffectivelyEnabled(preference: Bool) -> Bool {
        preference && enabled == true
    }

    /// The liveness mode this record vouches for.
    public var effectiveLivenessMode: LivenessMode { livenessMode ?? .blinkAndMovement }

    public enum Problem: Equatable, Sendable {
        case templateChanged
        case thresholdChanged
        case livenessChanged
    }

    /// nil when everything matches.
    public func problem(templateSHA256 actual: String?, threshold current: Float, livenessMode currentMode: LivenessMode) -> Problem? {
        guard let expected = templateSHA256, let actual, expected == actual else { return .templateChanged }
        guard abs(threshold - current) < 0.0001 else { return .thresholdChanged }
        guard effectiveLivenessMode == currentMode else { return .livenessChanged }
        return nil
    }
}
