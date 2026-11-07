# FaceUnlock

A macOS menu-bar app that unlocks your Mac's **lock screen** when the built-in
webcam recognises your face. All processing is on-device; the app makes no
network connections.

> **This is a convenience feature, not a security feature.** Read
> [Security limitations](#security-limitations) before enabling it.

Requires macOS 15+, Xcode / Swift 6 toolchain to build.

## Install

```bash
./build.sh                       # swift build -c release, assembles + signs build/FaceUnlock.app
cp -R build/FaceUnlock.app ~/Applications/   # or /Applications
open ~/Applications/FaceUnlock.app
```

A face icon appears in the menu bar. Then grant permissions (the menu shows
anything missing at the top):

1. **Camera** – menu → *Camera: not yet allowed – Allow…* (or it is asked the
   first time you enrol).
2. **Accessibility** – menu → *Accessibility: needed – Grant…*, then enable
   FaceUnlock in System Settings → Privacy & Security → Accessibility. This is
   needed to type your password on the lock screen.

`build.sh` signs with an Apple Development identity (override with
`FACEUNLOCK_SIGN_ID=<sha1 or name>`, or `-` for ad-hoc). With a stable
identity, the Camera/Accessibility grants and Keychain access survive
rebuilds. If it falls back to **ad-hoc** signing (no identity found), macOS
ties those to the exact build: after each rebuild re-grant Camera and
Accessibility and use *Change password…* again. The menu warns if the stored
password can't be read without a prompt (nobody can answer a prompt at the
lock screen).

## Set up

FaceUnlock opens a **Setup** window on first launch (and whenever a required
step is missing). It also opens when you launch the app again from Spotlight or
Finder, and from **Setup…** at the top of the menu-bar menu. That's useful
because the menu-bar icon can be hidden behind the notch. It walks
through seven steps, ticking each one off live: Camera access → Accessibility
→ Login password → Enrol face → Test recognition → Turn on (plus Launch at
login, on by default) → Lock-screen test. Each step unlocks once the previous
ones are done.

The **lock-screen test** locks the screen after a 3-second countdown. Wait
about 5 seconds, then move the mouse or press Shift and look at the camera.
The outcome of every attempt at the lock screen is stored as a small record:
time, result, and a reason such as no face, best score, no blink, or front
window owner. It never contains the password. When you come back, the step
explains what happened and what to do.

Within one Setup session, a password you just verified (step 3 or any
password prompt) is reused for 5 minutes, so you aren't asked again. Only a
timestamp is kept.

The individual steps, also available from the menu:


1. **Set password…** – enter your Mac login password. It is verified with the
   OpenDirectory framework (in-process) and then stored only in your login
   Keychain (generic password, service `uk.co.sid.faceunlock`).
2. **Enrol face…** – confirm with your login password, then follow the prompts (look straight, slightly left, right,
   up). About 18 good-quality frames are captured; only numeric embeddings are
   saved to `~/Library/Application Support/FaceUnlock/face-template.json`
   (folder 0700, file 0600). A SHA-256 of that file and the match threshold are
   stored in a second Keychain item; if either is changed behind FaceUnlock's
   back, the menu shows *Template changed – re-enrol* and nothing unlocks.
   Only the Mac's built-in camera is used (not iPhone/Continuity, external or
   virtual cameras), and unlock uses the same camera as enrolment.
3. **Test recognition…** – live preview with match score, consecutive matches,
   blink and head-movement status. Blink once and move your head slightly; it
   should say *PASS – would unlock*. Hold up a photo of yourself to see it fail.
   Nothing is typed from this window.
4. **Enabled** – tick it (asks for your login password). Optionally tick
   **Launch at login**.

Enrolling, changing the strictness, enabling and deleting data all require
your login password. Turning face unlock *off* never does.

### Match strictness

*Match strictness* (asks for your login password) sets the cosine-similarity threshold (default 0.55,
"Standard"). Both the averaged template and the best single enrolment sample
must reach it on 3 consecutive frames. Use *Test recognition…* to see your
typical score; pick the strictest setting that still recognises you reliably.
Changing the value with `defaults write` is treated as tampering: unlock
stops until you choose a strictness in the menu again.

## How it works

- **Trigger**: listens for `com.apple.screenIsLocked/Unlocked`, display wake,
  system wake and screensaver stop, and polls the authoritative lock state
  (`CGSessionCopyCurrentDictionary`) once a second. An attempt starts on a
  wake only if it came with keyboard/mouse/trackpad input or the lid was just
  opened, or on such input while the screen is locked. Nothing happens in the
  first 5 s after locking.
- **Attempt**: the camera runs for at most **10 s**, then turns off.
- **Recognition**: Vision face detection + 76-point landmarks → 5-point
  alignment to a 112×112 crop → **SFace** (MobileFaceNet) Core ML model →
  128-d embedding → cosine similarity against the enrolled template.
- **Liveness**: within the attempt you must **blink** (eyes open → both closed
  briefly → open, measured from the landmark eye contours, with checks that
  reject a tilted photo) **and** move your head slightly (yaw or pitch varies by
  ≥ 2.5°). Liveness evidence only counts from frames that match you, and at
  least 3 matching frames are needed after the blink. Any frame without a
  matching single face (no face, two faces, someone else, or a face that
  couldn't be read) resets all evidence.
- **Unlock**: on success it wakes the display, clears the password field and
  types the password one Unicode character at a time (so non-US layouts
  work), then Return. Before the clear step, before each character and
  before Return it re-checks that this session's screen is still locked and
  that the front full-screen window belongs to `loginwindow`; it stops at once
  if not, or if the Mac goes to sleep. The password is held in a buffer
  that is zeroed afterwards. Copies inside macOS (Keychain, event system,
  the password field) can't be wiped.
- **Lockout**: after **3 failed attempts** in one lock session (attempts where
  no face was seen don't count; going to sleep mid-attempt does), after **5
  attempts in total**, or if a typed password doesn't unlock the screen within
  6 s, FaceUnlock stops trying until you unlock manually.

## Security limitations

- **A webcam is not Face ID.** There is no depth or IR sensor. The blink and
  head-movement checks stop a printed photo or a still image on a phone, but a
  **video** of you (or a good mask) can pass. Someone with such a video and
  physical access to your Mac can unlock it.
- **Your login password is stored in your Keychain** and typed by the app.
  Anything that can read that Keychain item, or that runs as you with
  Accessibility permission, could misuse it.
- **It does not work at boot, after a restart, with FileVault pre-boot
  unlock, at the login window or for another user's session.** Only the
  screen lock of a session you have already logged into (and unlocked at
  least once since FaceUnlock started).
- Face templates are biometric data; they are stored only as numbers, in your
  home folder with owner-only permissions.
- Matching quality depends on lighting. Recognition thresholds were chosen
  conservatively but have not been calibrated against a large set of faces;
  check your own scores with *Test recognition…*.

## Disable / remove

- Untick **Enabled** in the menu (takes effect immediately), or quit the app.
- **Delete face data and password…** (asks for your login password) removes
  the template file and both Keychain items.
- Untick **Launch at login**, then delete the app. Optionally remove
  `~/Library/Application Support/FaceUnlock` and the app's entries in System
  Settings → Privacy & Security → Camera / Accessibility.

## Development

```bash
swift build        # debug build
swift test         # unit tests (matching, blink state machine, head pose, lockout, model parity)
./build.sh         # release .app in build/
```

`Models/SFace.mlpackage` was produced by `tools/convert_sface.py` from OpenCV
Zoo's `face_recognition_sface_2021dec.onnx` (Apache-2.0). See `NOTICE` for
licences and attribution.
