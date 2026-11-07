# FaceUnlock

[![CI](https://github.com/h2oracle/FaceUnlock/actions/workflows/ci.yml/badge.svg)](https://github.com/h2oracle/FaceUnlock/actions/workflows/ci.yml)

FaceUnlock is a small macOS menu-bar app that unlocks your Mac's **lock
screen** when it recognises your face through the built-in camera, a bit
like Face ID on an iPhone. Recognition runs entirely on your Mac using Apple's
Vision and Core ML frameworks. When it is sure it's you and that you're a
live person, it types your login password into the lock screen for you.

> [!WARNING]
> **Read this before installing. FaceUnlock is a convenience feature, not a
> security upgrade.**
>
> - A webcam can't do what Face ID's depth sensor does. A **video** of you, a
>   good mask, or a convincingly moved photo may unlock your Mac.
> - It works by **typing your login password**, which it keeps in your login
>   Keychain.
> - It only works for the screen lock of a session you're already logged into.
>   It does **not** work at boot, at the FileVault unlock screen or at the
>   login window.
> - It uses **private macOS APIs**: a SkyLight window-server space so its
>   indicator can appear on the lock screen, and `SACLockScreenImmediate` for
>   the setup lock test. A macOS update could break them.
> - In the default mode the **camera is on whenever the lock screen is
>   showing** and the display is awake.
> - Someone using your unlocked session can't re-enrol a different face,
>   change the settings or turn it on without your login password, and
>   editing its files or preferences behind its back disables it. They
>   *can* turn face unlock off.

## Features

- Unlocks the lock screen by recognising your face, with no key press needed in
  the default mode.
- Liveness checks: *Natural movement* (no blink needed) or *Blink + movement*.
- iPhone-style Face ID indicator on the lock screen: scanning, a tick on a
  match, and a shake on "Face Not Recognised".
- Guided Setup window that ticks off each step and ends with a real
  lock-screen test.
- Strict matching. Several consecutive matching frames and exactly one face in
  view are required.
- Failed attempts are limited, and it stops immediately if a typed password
  doesn't work.
- Everything stays on-device, with no network access at all.
- A diagnostics log explains why an attempt did or didn't unlock.
- Launch at login.

## How it works

1. **Detect**: Vision finds faces and 76 facial landmarks in each camera frame
   (up to 30 fps). Exactly one face must be in view.
2. **Align and embed**: the face is warped onto a standard 112×112 5-point
   template and turned into a 128-number embedding by the **SFace**
   (MobileFaceNet) model, run with Core ML.
3. **Match**: the embedding is compared, using cosine similarity, with the
   averaged embedding from your enrolment and with the closest enrolment
   sample. Both must reach the threshold on 3 consecutive frames.
4. **Liveness**: evidence is only taken from frames that match you. Any frame
   that doesn't match resets it.
5. **Unlock**: it re-checks that your session's lock screen is the window in
   front, then types the password one character at a time and presses Return.

Only numbers describing your face (embeddings) are saved. Images are never
written to disk.

## Requirements

- macOS 15 Sequoia or later
- Apple Silicon Mac
- Built-in camera (FaceUnlock deliberately ignores iPhone/Continuity, external
  and virtual cameras)

## Install

### Download a release

1. Download `FaceUnlock-<version>.zip` from the
   [Releases](https://github.com/h2oracle/FaceUnlock/releases) page and
   check it against the `.sha256` file if you like
   (`shasum -a 256 FaceUnlock-<version>.zip`).
2. Unzip it and move **FaceUnlock.app** to `/Applications` or
   `~/Applications`.
3. If the app isn't notarised, macOS will refuse to open it the first time.
   Either **right-click (Control-click) the app › Open › Open**, or try to
   open it, then go to **System Settings › Privacy & Security** and click
   **Open Anyway**.

### Build from source

```bash
git clone https://github.com/h2oracle/FaceUnlock.git
cd FaceUnlock
./build.sh                      # creates build/FaceUnlock.app
cp -R build/FaceUnlock.app ~/Applications/
open ~/Applications/FaceUnlock.app
```

`build.sh` signs **ad-hoc** by default. To use your own signing identity,
copy `signing.local.env.example` to `signing.local.env` (git-ignored) and set
`FACEUNLOCK_SIGN_ID` to a hash from `security find-identity -v -p codesigning`.
You can also export `FACEUNLOCK_SIGN_ID` in your shell. With a stable
identity, macOS keeps the Camera and Accessibility permissions and the
Keychain access when you rebuild. With ad-hoc signing you have to grant them
again after every build. The bundle
identifier (`uk.co.sid.faceunlock`) is just the project's default. Changing it
gives you a separate app with its own settings and permissions.

## Setup

FaceUnlock opens its **Setup** window on first launch. You can open it any
time from **Setup…** in the menu-bar menu, or by opening the app again from
Spotlight or Finder. Each step unlocks once the earlier ones are done:

1. **Camera access**: allow the camera.
2. **Accessibility**: needed to type your password. *Open Settings…* takes you
   to the right pane, and the tick appears once you've switched FaceUnlock on.
3. **Login password**: entered once and checked with macOS's directory
   service. It is stored only in your login Keychain.
4. **Enrol your face**: confirm with your password, then follow the on-screen
   prompts (look straight, slightly left, right and up).
5. **Test recognition**: a live preview with your match score, eye openness,
   head movement and liveness status. The step is ticked after a real *PASS*.
6. **Turn on**: enable face unlock (asks for your password), with *Launch at
   login* and *Start scanning* options.
7. **Lock-screen test**: locks the screen after a 3-second countdown so you
   can try it for real. When you come back, the step tells you what happened
   and what to do if it didn't work.

Within one Setup session, a password you've just confirmed is reused for 5
minutes, so you aren't asked again when you turn face unlock on or change the
strictness. Only the time of confirmation is kept. The reuse ends when the
screen locks or the Mac sleeps. Enrolling, turning liveness off and deleting
data always ask again.

## Settings

All settings are in the menu-bar menu. The first two are also in the Setup
window.

- **Liveness** (asks for your password):
  - *Natural movement* (default): no blink needed. While you're recognised,
    your head must turn a few degrees (≥ 3° between the ends of the
    movement), and the landmarks must shift the way only a 3D face does
    (parallax). A picture on a flat surface moves like a single plane
    however it's tilted or waved, so photos on paper or a phone fail. A still
    real head waits until you move slightly; with normal movement it passes
    in about 0.5–1.5 s. A video of you, a 3D mask or a curved print may
    still pass. The thresholds were tuned on simulated faces with realistic
    landmark noise, not on a large real-world dataset.
  - *Blink + movement*: a natural blink plus slight head movement. This is the
    strongest webcam check, but a video of you can still pass.
  - *Off*: face match only. A photo of you can unlock. Not recommended.
- **Match strictness** (asks for your password): Relaxed 0.55, Standard 0.70
  (default) or Strict 0.80. *Test recognition* shows your typical score and
  suggests a stricter value if you have plenty of headroom.
- **Start scanning** (no password needed, because it doesn't affect matching):
  - *Automatically when the lock screen shows* (default): the camera scans
    while the lock screen is visible and the display is on, so you don't need
    to press anything. macOS turns the display off at the lock screen after a
    short time, and that stops the camera. If no face is seen for 60 s, it
    pauses until you move the mouse or press a key.
  - *Only after I move the mouse or press a key*: each input starts a scan of
    up to 10 s.

**Limits:** each of these counts as a *failed look*:

- a face that doesn't match for 2 s in total. Covering the camera or adding
  a second face doesn't reset the count;
- a brief appearance (6+ frames) of a face that never matched;
- a face that matches but doesn't pass the liveness check for 3 s, such as
  a photo of you.

Frames with no face never count. After 3 failed looks, scanning stops until
the display sleeps and wakes again. It stops until you unlock manually after
5 failed looks in one lock session, after a face has been in view for 2
minutes in total, or if a typed password didn't unlock the Mac. If the Mac
sleeps before that is confirmed, it is treated as not unlocked.

## Security model and limitations

See the warning at the top and [SECURITY.md](SECURITY.md) for the threat
model. In short:

- It resists another person's face and flat photos (still or moved). It
  does **not** reliably resist a video, a mask or a skilled attacker with
  physical access.
- Matching is strict by default, and every typed key is preceded by a check
  that your own session's lock screen is in front.
- The Keychain keeps an integrity record: a SHA-256 of the face template,
  plus the threshold, the liveness setting and whether face unlock is on.
  Only enrolment writes a new template hash. Setting changes start from the
  verified record, never from the files or preferences. If the template or
  a setting is changed behind FaceUnlock's back, it refuses to unlock and
  asks you to re-enrol or choose the setting again. If the "enabled"
  preference doesn't match the record, it stays off. Other apps running as
  you can't read, change or delete these Keychain items without a macOS
  prompt asking you to allow it.
- The password is decoded into memory the app controls and overwritten after
  typing. Copies inside macOS (Keychain, event system, password field) are
  outside its control.

## Privacy

- Everything runs on your Mac. FaceUnlock contains no networking code and
  sends nothing anywhere.
- Camera frames are processed in memory and never saved.
- Stored data:
  - `~/Library/Application Support/FaceUnlock/face-template.json`: face
    embeddings (numbers only). The folder is owner-only (0700) and the file
    is owner-only (0600).
  - `~/Library/Application Support/FaceUnlock/diagnostics.log`: attempt
    diagnostics with scores, states, timings and reasons. It never contains
    the password, embeddings or images. It is 0600 and rotated at about 1 MB.
  - Login Keychain, service `uk.co.sid.faceunlock`: the password
    (`macos-login-password`) and the integrity record (`integrity`).
  - Preferences (`defaults read uk.co.sid.faceunlock`): settings and the last
    lock-screen attempt result.

## Troubleshooting

- **I can't see the menu-bar icon.** On Macs with a notch, a full menu bar
  can hide it. Open FaceUnlock again from Spotlight or Finder to get the
  Setup window, which has everything the menu has.
- **It didn't unlock.** The *Lock-screen test* step shows what went wrong.
  More detail is in `~/Library/Application Support/FaceUnlock/diagnostics.log`,
  and key lines also go to the unified log:
  `log show --last 10m --predicate 'subsystem == "uk.co.sid.faceunlock"'`.
- **Permissions look granted but the app says they're missing.** This usually
  happens after a rebuild with a different signature. Remove FaceUnlock from
  System Settings › Privacy & Security › Camera / Accessibility, add it again,
  and restart the app.
- **A Keychain prompt asks about FaceUnlock.** Click *Always Allow*. Nobody
  can answer a prompt at the lock screen, so FaceUnlock never shows one
  there. If the stored password can't be read without a prompt, the menu
  says so; save the password again in Setup step 3.
- **"Template changed – re-enrol".** The template file, threshold or liveness
  setting no longer matches the Keychain record. Re-enrol, or choose the
  setting again in the menu.

## Uninstall

1. Quit FaceUnlock from its menu (or run `killall FaceUnlock`).
2. Optional, from the menu first: **Delete face data and password…**.
3. Delete the app from `/Applications` or `~/Applications`.
4. Remove its data:

   ```bash
   rm -rf ~/Library/Application\ Support/FaceUnlock
   security delete-generic-password -s uk.co.sid.faceunlock -a macos-login-password
   security delete-generic-password -s uk.co.sid.faceunlock -a integrity
   defaults delete uk.co.sid.faceunlock
   ```

5. Remove FaceUnlock from System Settings › Privacy & Security ›
   Accessibility (and Camera), and from System Settings › General › Login
   Items if it's listed.

## Building and testing

```bash
swift build      # debug build
swift test       # unit tests (no camera or permissions needed)
./build.sh       # release app bundle in build/
./release.sh     # dist/FaceUnlock-<version>.zip + .sha256 (notarises if configured)
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

### Project layout

| Path | What |
| --- | --- |
| `Sources/FaceUnlockCore/` | Testable logic and the Vision / Core ML face pipeline |
| `Sources/FaceUnlock/` | The menu-bar app: camera, lock handling, Keychain, typing, HUD, Setup window |
| `Tests/FaceUnlockCoreTests/` | Unit tests |
| `Models/SFace.mlpackage` | Face-embedding model (Apache-2.0) |
| `tools/convert_sface.py` | Converts the original ONNX model to Core ML with a parity check |
| `docs/` | Documentation assets (screenshots to come) |

## Credits

- **SFace** face-recognition model by Yaoyao Zhong et al., distributed by
  [OpenCV Zoo](https://github.com/opencv/opencv_zoo) under Apache-2.0.
- Approach informed by [Glance](https://github.com/jonnyoo/glance) (MIT) and
  [SkyLightWindow](https://github.com/Lakr233/SkyLightWindow) (MIT).

Full attributions are in [NOTICE](NOTICE).

## Licence

[MIT](LICENSE). The bundled SFace model is Apache-2.0; see
`Models/LICENSE-SFace.txt`.
