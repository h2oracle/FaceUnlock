import Foundation

/// Outcome of one face-unlock attempt at the lock screen. Contains no
/// secrets: only scores, process names and error codes.
public enum AttemptOutcome: Codable, Equatable, Sendable {
    case unlocked
    case noFace
    case noMatch(bestScore: Float)
    case noBlink
    case noHeadMovement
    /// Matched, blinked and moved, but never all together for long enough.
    case notSteady
    case multipleFaces
    case frontWindowRefused(owner: String)
    case passwordRejected
    case lockedOut
    case keychainError(String)
    case typingStopped(String)
    case cameraError(String)
    /// Not attempted because setup is incomplete (permission missing etc.).
    case notReady(String)

    public var isSuccess: Bool { self == .unlocked }

    /// Plain-English summary of what happened.
    public var summary: String {
        switch self {
        case .unlocked: return "Face unlock worked: the Mac was unlocked."
        case .noFace: return "No face was seen during the attempt."
        case .noMatch(let best):
            return String(format: "Your face wasn't recognised (best score %.2f).", best)
        case .noBlink: return "You were recognised, but no blink was detected."
        case .noHeadMovement: return "You were recognised and blinked, but no head movement was detected."
        case .notSteady: return "Recognition and liveness never held together long enough."
        case .multipleFaces: return "More than one face was in view."
        case .frontWindowRefused(let owner):
            return "Didn't type the password: the window in front belonged to “\(owner)”, not the lock screen."
        case .passwordRejected: return "The password was typed but the Mac stayed locked."
        case .lockedOut: return "Stopped trying after too many attempts in this lock session."
        case .keychainError(let detail): return "Couldn't read the stored password (\(detail))."
        case .typingStopped(let reason): return "Stopped typing the password (\(reason))."
        case .cameraError(let detail): return "The camera couldn't be used (\(detail))."
        case .notReady(let reason): return "Face unlock didn't run: \(reason)."
        }
    }

    /// What to do about it (empty on success).
    public var advice: String {
        switch self {
        case .unlocked: return ""
        case .noFace:
            return "After locking, wait about 5 seconds, then move the mouse or press Shift and look at the camera."
        case .noMatch:
            return "Check lighting, then use Test recognition. Re-enrol, or choose a more relaxed strictness, if your scores are low."
        case .noBlink: return "Blink once, normally, while looking at the camera."
        case .noHeadMovement: return "Move your head slightly (a small nod or turn) while looking at the camera."
        case .notSteady: return "Hold still facing the camera for a moment after blinking."
        case .multipleFaces: return "Make sure only your face is in view."
        case .frontWindowRefused:
            return "Something is covering the lock screen. Quit apps that draw full-screen overlays and try again."
        case .passwordRejected: return "Your login password may have changed. Save it again in step 3."
        case .lockedOut: return "Unlock manually; the counter resets at the next lock."
        case .keychainError: return "Save the password again in step 3."
        case .typingStopped: return "Try the lock-screen test again."
        case .cameraError: return "Check the camera permission and that no other app is using the camera."
        case .notReady: return "Finish the earlier setup steps."
        }
    }
}

public struct AttemptRecord: Codable, Equatable, Sendable {
    public var time: Date
    public var outcome: AttemptOutcome

    public init(time: Date = Date(), outcome: AttemptOutcome) {
        self.time = time
        self.outcome = outcome
    }
}

/// Accumulates what happened over a whole attempt, independent of the
/// evaluator's resets, to explain a failure afterwards.
public struct AttemptDiagnostics: Equatable, Sendable {
    public private(set) var sawFace = false
    public private(set) var sawMultipleFaces = false
    public private(set) var bestScore: Float?
    public private(set) var anyMatch = false
    public private(set) var blinked = false
    public private(set) var headMoved = false

    public init() {}

    public mutating func observe(_ s: UnlockEvaluator.Snapshot) {
        if s.faceCount > 0 { sawFace = true }
        if s.faceCount > 1 { sawMultipleFaces = true }
        if let score = s.score {
            bestScore = max(bestScore ?? -1, score.centroid)
        }
        if s.frameMatched { anyMatch = true }
        if s.blinked { blinked = true }
        if s.poseVaried { headMoved = true }
    }

    /// Why an attempt that didn't pass failed, most fundamental reason first.
    public var failureOutcome: AttemptOutcome {
        if !sawFace { return .noFace }
        if !anyMatch {
            if bestScore == nil && sawMultipleFaces { return .multipleFaces }
            return .noMatch(bestScore: bestScore ?? 0)
        }
        if !blinked { return .noBlink }
        if !headMoved { return .noHeadMovement }
        return .notSteady
    }
}
