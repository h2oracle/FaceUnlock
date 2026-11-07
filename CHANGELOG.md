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
  landmarks as the head turns) to reject flat photos, still or moved. A
  natural blink in recognised frames with slight movement also passes.
- Attention requirement: the final 5 matched frames must face the screen
  (within 18° of the owner's enrolled or learned screen-facing pose) with both eyes
  open and a score at least 0.05
  above the threshold. Loose legacy thresholds get a prominent warning.
- Matching uses the better of the averaged template and the top-3 sample
  mean; enrolment captures ~30 samples across distances and postures;
  adaptive samples after strong unlocks (max 15, FIFO); small background
  faces are ignored.
- Frames are judged by a quality gate (angle, size, cut off, capture
  quality). A missing Vision pose is estimated from the landmarks rather
  than rejected.
- Failed-look lockout that can't be reset by covering the lens: 3 per scan (re-armed by input
  after a 2 s pause), 5 per lock session, and a 2-minute face-time cap. It also counts
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
