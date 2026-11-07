import Foundation

/// Kept in the Keychain next to the password: what the template file and
/// the match threshold are supposed to be. A same-user process can edit
/// files in ~/Library or `defaults`, but can't silently rewrite this item
/// (it would need to delete and re-create it, which then fails the
/// prompt-free read). If either doesn't match, face unlock refuses to run.
public struct IntegrityRecord: Codable, Equatable, Sendable {
    public var templateSHA256: String?
    public var threshold: Float

    public init(templateSHA256: String?, threshold: Float) {
        self.templateSHA256 = templateSHA256
        self.threshold = threshold
    }

    public enum Problem: Equatable, Sendable {
        case templateChanged
        case thresholdChanged
    }

    /// nil when everything matches.
    public func problem(templateSHA256 actual: String?, threshold current: Float) -> Problem? {
        guard let expected = templateSHA256, let actual, expected == actual else { return .templateChanged }
        guard abs(threshold - current) < 0.0001 else { return .thresholdChanged }
        return nil
    }
}
