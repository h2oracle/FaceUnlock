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
