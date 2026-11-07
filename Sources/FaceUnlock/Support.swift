import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import FaceUnlockCore
import Foundation
import IOKit
import os

/// Never pass secrets to this logger.
let log = Logger(subsystem: "uk.co.sid.faceunlock", category: "app")

// MARK: - Settings

@MainActor
enum Settings {
    private static let defaults = UserDefaults.standard
    private static let enabledKey = "enabled"
    private static let thresholdKey = "matchThreshold"

    static var isEnabled: Bool {
        get { defaults.bool(forKey: enabledKey) }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    /// Cosine threshold; also settable via
    /// `defaults write uk.co.sid.faceunlock matchThreshold -float 0.6`.
    static var matchThreshold: Float {
        get {
            guard defaults.object(forKey: thresholdKey) != nil else { return MatchPolicy.defaultThreshold }
            return MatchPolicy(threshold: defaults.float(forKey: thresholdKey)).threshold
        }
        set { defaults.set(MatchPolicy(threshold: newValue).threshold, forKey: thresholdKey) }
    }

    static var policy: MatchPolicy { MatchPolicy(threshold: matchThreshold) }

    private static let scanStartKey = "scanStartMode"

    /// When lock-screen scanning starts. Not part of the integrity record:
    /// it changes when the camera runs, not how strict matching is.
    static var scanStartMode: ScanStartMode {
        get { defaults.string(forKey: scanStartKey).flatMap(ScanStartMode.init(rawValue:)) ?? .automatic }
        set { defaults.set(newValue.rawValue, forKey: scanStartKey) }
    }

    static var hasMatchThreshold: Bool { defaults.object(forKey: thresholdKey) != nil }

    private static let livenessKey = "livenessMode"

    static var hasLivenessMode: Bool { defaults.string(forKey: livenessKey) != nil }

    /// Liveness requirement. Like the threshold, it's also recorded in the
    /// Keychain integrity item; a mismatch blocks unlocking.
    static var livenessMode: LivenessMode {
        get { defaults.string(forKey: livenessKey).flatMap(LivenessMode.init(rawValue:)) ?? .default }
        set { defaults.set(newValue.rawValue, forKey: livenessKey) }
    }
}

// MARK: - Diagnostics file

/// Plain-text attempt diagnostics in
/// ~/Library/Application Support/FaceUnlock/diagnostics.log (0600), rotated
/// to diagnostics.log.1 at ~1 MB. Only numbers, states and reasons: never the
/// password, embeddings or images. Writes happen on a private serial queue.
enum Diagnostics {
    private static let queue = DispatchQueue(label: "uk.co.sid.faceunlock.diagnostics", qos: .utility)
    private static let maximumBytes: UInt64 = 1_000_000

    static var fileURL: URL { TemplateStore.standard.directory.appendingPathComponent("diagnostics.log") }

    static func write(_ message: String) {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
        let line = "\(stamp) \(message)\n"
        queue.async { append(line) }
    }

    private static func append(_ line: String) {
        let fm = FileManager.default
        let url = fileURL
        let dir = url.deletingLastPathComponent()
        do {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size > maximumBytes {
                let old = dir.appendingPathComponent("diagnostics.log.1")
                try? fm.removeItem(at: old)
                try fm.moveItem(at: url, to: old)
            }
            if !fm.fileExists(atPath: url.path) {
                guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            // Diagnostics must never affect unlocking.
        }
    }
}

// MARK: - Permissions

enum Permissions {
    static var cameraStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }
    static var cameraAuthorized: Bool { cameraStatus == .authorized }

    /// Silent check, never prompts.
    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system Accessibility prompt (user-initiated only).
    static func promptForAccessibility() {
        // Value of kAXTrustedCheckOptionPrompt (a C global Swift 6 flags as unsafe).
        let key = "AXTrustedCheckOptionPrompt"
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Session lock state

enum SessionState {
    struct Snapshot {
        var screenLocked: Bool
        /// This user's session owns the console (false during fast user
        /// switching / at the login window of another user).
        var onConsole: Bool
        var loginDone: Bool
    }

    /// Authoritative state from the window server (notifications can be
    /// spoofed by any process of the same user, this cannot).
    static func current() -> Snapshot {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return Snapshot(screenLocked: false, onConsole: false, loginDone: false)
        }
        return Snapshot(
            screenLocked: (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false,
            onConsole: (dict[kCGSessionOnConsoleKey as String] as? Bool) ?? false,
            loginDone: (dict[kCGSessionLoginDoneKey as String] as? Bool) ?? false
        )
    }

    static var displayAsleep: Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }

    /// Seconds since the last keyboard/mouse/trackpad event, system-wide.
    static var secondsSinceUserInput: TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return .infinity }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: any)
    }
}

// MARK: - Lid

enum Clamshell {
    /// Current lid state from IOPMrootDomain ("AppleClamshellState"), or nil
    /// on Macs without a lid / if unavailable. Read-only registry query.
    static func isClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return value as? Bool
    }
}

// MARK: - Setup state (non-sensitive, UserDefaults)

@MainActor
enum SetupStore {
    private static let defaults = UserDefaults.standard
    private static let lastAttemptKey = "lastAttemptRecord"
    private static let testPassedKey = "testPassedTemplateSHA256"
    private static let launchChoiceKey = "launchAtLoginChosen"
    private static let learnedBaselineKey = "learnedBaselinePose"

    /// How the owner faces the screen, learned from successful unlocks and
    /// Test passes (moving average). Only used for templates enrolled before
    /// the baseline was stored in them. It's a convenience, not a security
    /// value: the clamp (±20° yaw, ±25° pitch) and the score margin bound it.
    static var learnedBaselinePose: PoseBaseline? {
        get { defaults.data(forKey: learnedBaselineKey).flatMap { try? JSONDecoder().decode(PoseBaseline.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: learnedBaselineKey) }
    }

    static func refineLearnedBaseline(with pose: PoseBaseline) {
        learnedBaselinePose = PoseBaseline.blended(learnedBaselinePose, with: pose)
    }

    /// Most recent lock-screen attempt (time, outcome, reason; no secrets).
    static var lastAttempt: AttemptRecord? {
        get {
            guard let data = defaults.data(forKey: lastAttemptKey) else { return nil }
            return try? JSONDecoder().decode(AttemptRecord.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: lastAttemptKey)
            } else {
                defaults.removeObject(forKey: lastAttemptKey)
            }
        }
    }

    /// Digest of the template for which "Test recognition" last passed;
    /// re-enrolling makes the test step pending again.
    static var testPassedForDigest: String? {
        get { defaults.string(forKey: testPassedKey) }
        set { defaults.set(newValue, forKey: testPassedKey) }
    }

    /// Whether the user has explicitly set Launch at login (otherwise the
    /// setup window defaults it to on when face unlock is turned on).
    static var launchAtLoginChosen: Bool {
        get { defaults.bool(forKey: launchChoiceKey) }
        set { defaults.set(newValue, forKey: launchChoiceKey) }
    }
}

// MARK: - Locking the screen (setup's lock-screen test)

enum ScreenLocker {
    /// Locks the screen. Uses `SACLockScreenImmediate` from the system
    /// login.framework (what the menu-bar "Lock Screen" command uses; private
    /// API, looked up at run time). Falls back to posting Ctrl+Cmd+Q, which
    /// needs Accessibility permission.
    static func lockNow() {
        typealias LockFunction = @convention(c) () -> Int32
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        if let handle = dlopen(path, RTLD_LAZY), let symbol = dlsym(handle, "SACLockScreenImmediate") {
            let lock = unsafeBitCast(symbol, to: LockFunction.self)
            if lock() == 0 { return }
        }
        postLockShortcut()
    }

    private static func postLockShortcut() {
        let source = CGEventSource(stateID: .hidSystemState)
        let q: CGKeyCode = 0x0C
        let flags: CGEventFlags = [.maskCommand, .maskControl]
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: q, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: q, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
