import AppKit
import CoreGraphics
import Darwin
import Foundation
import IOKit.pwr_mgt

/// Set by the coordinator when the lock session ends or the Mac sleeps;
/// the typing loop checks it before every key.
final class TypingCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

/// Is the macOS lock screen what's actually in front?
///
/// The screen-lock UI is expected to be drawn by the loginwindow process
/// (/System/Library/CoreServices/loginwindow.app). This has not been
/// observed on a locked macOS 26 screen yet; if the owner differs, typing is
/// refused (fails closed) and the log names the actual owner. Small always-on-top
/// windows (menu-bar extras, camera indicators) can sit above it, so the
/// check is: the front-most on-screen window that covers (nearly) the whole
/// main display must belong to loginwindow, verified by executable path
/// rather than by the spoofable process name alone.
enum LockScreenGuard {
    static let loginWindowPath = "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"

    /// nil if the lock screen is in front, otherwise a reason (for the log;
    /// contains only process names, never window contents).
    static func problem() -> String? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return "window list unavailable"
        }
        let display = CGDisplayBounds(CGMainDisplayID())
        let minimumArea = display.width * display.height * 0.9
        // CGWindowList returns windows front-to-back.
        for window in windows {
            guard let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            let alpha = (window[kCGWindowAlpha as String] as? Double) ?? 1
            let covered = bounds.intersection(display)
            guard alpha > 0, !covered.isNull, covered.width * covered.height >= minimumArea else { continue }
            let pid = (window[kCGWindowOwnerPID as String] as? Int32) ?? -1
            let owner = (window[kCGWindowOwnerName as String] as? String) ?? "?"
            if executablePath(of: pid) == loginWindowPath { return nil }
            return "front full-screen window belongs to \(owner)"
        }
        return "no full-screen window in front"
    }

    private static func executablePath(of pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Types the password into the lock-screen password field using synthetic
/// keyboard events. Requires Accessibility permission.
///
/// Each Unicode scalar is sent as its own key-down/key-up pair carrying the
/// character via `CGEventKeyboardSetUnicodeString`, so the active keyboard
/// layout (UK, German, AZERTY, …) doesn't change what gets typed.
enum KeyTyper {
    enum TypingError: Error, CustomStringConvertible {
        case eventCreationFailed
        case aborted(String)

        var description: String {
            switch self {
            case .eventCreationFailed: return "couldn't create keyboard event"
            case .aborted(let why): return "stopped typing: \(why)"
            }
        }
    }

    private static let returnKey: CGKeyCode = 0x24
    private static let deleteKey: CGKeyCode = 0x33
    private static let rightArrowKey: CGKeyCode = 0x7C
    private static let commandKey: CGKeyCode = 0x37

    /// Asserts user activity so the display is on (no-op if it already is).
    static func wakeDisplay() {
        var assertion: IOPMAssertionID = 0
        let result = IOPMAssertionDeclareUserActivity("FaceUnlock" as CFString, kIOPMUserActiveLocal, &assertion)
        if result == kIOReturnSuccess {
            IOPMAssertionRelease(assertion)
        }
    }

    /// Throws `.aborted` unless this session's screen is still locked, on
    /// the console, the lock screen is in front and nobody cancelled.
    private static func ensureSafe(_ cancellation: TypingCancellation) throws {
        if cancellation.isCancelled { throw TypingError.aborted("cancelled") }
        let state = SessionState.current()
        guard state.screenLocked, state.onConsole, state.loginDone else {
            throw TypingError.aborted("screen no longer locked for this session")
        }
        if let problem = LockScreenGuard.problem() { throw TypingError.aborted(problem) }
    }

    /// Clears the field, types `secret`, presses Return, checking safety
    /// before each step. Blocking (~15 ms per character).
    static func typeAndSubmit(_ secret: SecretUTF16, cancellation: TypingCancellation) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        try ensureSafe(cancellation)
        try clearField(source: source)
        try secret.forEachScalar { units in
            try ensureSafe(cancellation)
            try postUnicode(units, source: source)
        }
        try ensureSafe(cancellation)
        try postKey(returnKey, flags: [], source: source)
    }

    /// Removes anything already typed (e.g. a stray key press that woke the
    /// screen): Cmd+Right then Cmd+Delete. Both use layout-independent keys.
    private static func clearField(source: CGEventSource?) throws {
        try postKey(rightArrowKey, flags: .maskCommand, source: source)
        try postKey(deleteKey, flags: .maskCommand, source: source)
    }

    private static func postUnicode(_ units: UnsafeBufferPointer<UInt16>, source: CGEventSource?) throws {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw TypingError.eventCreationFailed
        }
        down.flags = []
        up.flags = []
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units.baseAddress)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units.baseAddress)
        down.post(tap: .cghidEventTap)
        usleep(6_000)
        up.post(tap: .cghidEventTap)
        usleep(6_000)
    }

    private static func postKey(_ key: CGKeyCode, flags: CGEventFlags, source: CGEventSource?) throws {
        let withCommand = flags.contains(.maskCommand)
        if withCommand {
            guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: true) else {
                throw TypingError.eventCreationFailed
            }
            cmdDown.flags = .maskCommand
            cmdDown.post(tap: .cghidEventTap)
            usleep(10_000)
        }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            throw TypingError.eventCreationFailed
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        usleep(10_000)
        up.post(tap: .cghidEventTap)
        usleep(10_000)
        if withCommand {
            guard let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: false) else {
                throw TypingError.eventCreationFailed
            }
            cmdUp.flags = []
            cmdUp.post(tap: .cghidEventTap)
            usleep(10_000)
        }
    }
}
