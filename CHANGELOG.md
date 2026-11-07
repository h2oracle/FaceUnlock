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
- Natural movement uses 3D parallax (homography residuals of the facial
  landmarks as the head turns) to reject flat photos, still or moved.
- Failed-look lockout that can't be reset by covering the lens: 3 per display
  wake, 5 per lock session, and a 2-minute face-time cap. It also counts
  brief unrecognised appearances and matched-but-not-live faces. It stops
  after a rejected password, including when sleep interrupts the
  confirmation, and pauses the camera after 60 seconds without a face.
- Password stored in the login Keychain, verified with OpenDirectory, typed
  layout-independently with lock-screen and front-window checks before every
  key.
- Keychain integrity record for the face template, threshold, liveness mode
  and enabled state. The login password is required to enrol, change
  strictness/liveness, enable or delete data. Reuse of a just-confirmed
  password ends at screen lock or sleep.
- Guided Setup window (camera, Accessibility, password, enrolment, test,
  turn on, lock-screen test) with live status.
- iPhone-style Face ID HUD on the lock screen.
- Diagnostics log with per-attempt summaries and timing breakdown.
- Launch at login.
