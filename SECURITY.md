# Security policy

FaceUnlock types your macOS login password on the lock screen, so security
reports are taken seriously.

## Reporting a vulnerability

Please **do not open a public issue**. Use GitHub's private vulnerability
reporting instead: on the repository page, go to **Security › Report a
vulnerability**. Include the macOS version, the FaceUnlock version or commit,
steps to reproduce, and what an attacker gains.

You should get an acknowledgement within a few days. Fixes are released as
soon as practical and credited in the changelog unless you'd rather stay
anonymous.

## Threat model (summary)

FaceUnlock is a convenience feature. It is **not** as secure as Face ID or
Touch ID, and it is not meant to protect against a determined attacker who
has physical access to your Mac.

**In scope (things it tries to resist):**
- Someone else's face unlocking your Mac (face matching with a strict
  threshold, consecutive matching frames, one face in view only).
- A still printed photo or a photo on a phone (liveness checks: natural
  movement, or blink + movement).
- Repeated guessing at the lock screen (failed-look limits per display wake
  and per lock session; it stops after one typed password that didn't work).
- Typing the password anywhere other than the lock screen (it re-checks
  before every key that this user's session is locked, on the console, and
  that the lock screen is the full-screen window in front).
- Silent tampering with the enrolled face, threshold or liveness setting by
  another process running as you (a SHA-256 of the template and the settings
  are kept in the Keychain; a mismatch blocks unlocking). Enrolling,
  changing strictness/liveness, enabling and deleting data all need the
  login password.

**Out of scope / known limitations:**
- A webcam has no depth or infrared sensor. A **video** of you, a good mask,
  or a sufficiently convincing moving photo can defeat the liveness checks.
- The login password is stored in your login Keychain. Malware running as
  you with Keychain access, or with Accessibility permission, can misuse it.
- It only works for the screen lock of a session that is already logged in.
  It never runs at boot, at the FileVault unlock screen or at the login
  window.
- It uses private macOS APIs (a SkyLight window-server space so the HUD
  shows on the lock screen, and `SACLockScreenImmediate` for the setup
  lock test). macOS updates may break them.
- In the default "watch" mode the camera is on whenever the lock screen is
  showing and the display is awake.

## Supported versions

Only the latest release receives security fixes.
