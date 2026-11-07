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
- Photos on paper or a screen, held still or moved around (natural
  movement: 3D parallax as the head turns; or blink + movement).
- Repeated attempts at the lock screen. Failed looks are counted per display
  wake and per lock session, and covering the lens or adding a second face
  doesn't reset the count. A matching face that never passes liveness also
  counts. Face time is capped at 2 minutes per lock session. It stops after
  one typed password that didn't work.
- Typing the password anywhere other than the lock screen (it re-checks
  before every key that this user's session is locked, on the console, and
  that the lock screen is the full-screen window in front).
- Silent tampering with the enrolled face, threshold, liveness setting or
  on/off state by another process running as you. These live in a Keychain
  integrity record (template SHA-256, threshold, liveness, enabled); a
  mismatch blocks unlocking or keeps it off. Setting changes start from the
  verified record, and only enrolment writes a new template hash.
  Enrolling, changing strictness/liveness, enabling and deleting data all
  need the login password. A password confirmed in the Setup window may be
  reused for 5 minutes for some changes, but never across a screen lock or
  sleep, and never for enrolling, turning liveness off or deleting data.
- Forging the Keychain items: tested on macOS 26 with a throwaway item.
  Another process running as you got `errSecAuthFailed` reading it and
  `errSecInvalidOwnerEdit` deleting it without user approval. Items it
  creates itself are partitioned to that process, so FaceUnlock can't read
  them without a prompt, and fails closed.

**Out of scope / known limitations:**
- A webcam has no depth or infrared sensor. A **video** of you, a good 3D
  mask, or a print bent into a convincing 3D shape can defeat the liveness
  checks. The natural-movement thresholds were tuned on simulated faces,
  not a large real-world dataset.
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
