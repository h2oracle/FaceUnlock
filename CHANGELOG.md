# Changelog

## 0.1.0 – 2026-11-07

First public release.

- Menu-bar app that unlocks the macOS lock screen when it recognises your
  face through the built-in camera.
- On-device face recognition: Vision face detection and landmarks, 5-point
  alignment, SFace (MobileFaceNet) Core ML embeddings, cosine matching
  against an averaged template, consecutive-frame requirement.
- Liveness modes: Natural movement (default; no blink), Blink + movement,
  Off.
- Start-scanning modes: automatic while the lock screen shows (default), or
  only after mouse/keyboard input.
- Failed-look lockout (3 per display wake, 5 per lock session), stop after a
  rejected password, 60-second no-face camera pause.
- Password stored in the login Keychain, verified with OpenDirectory, typed
  layout-independently with lock-screen and front-window checks before every
  key.
- Keychain integrity record for the face template, threshold and liveness
  mode; login password required to enrol, change strictness/liveness, enable
  or delete data.
- Guided Setup window (camera, Accessibility, password, enrolment, test,
  turn on, lock-screen test) with live status.
- iPhone-style Face ID HUD on the lock screen.
- Diagnostics log with per-attempt summaries and timing breakdown.
- Launch at login.
