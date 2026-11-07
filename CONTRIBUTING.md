# Contributing

Thanks for helping. FaceUnlock types the user's login password, so every
change is reviewed first for its security impact.

## Build and test

Requirements: macOS 15 or later, Xcode with a Swift 6 toolchain.

```bash
swift build          # debug build
swift test           # unit tests (no camera, Keychain or permissions needed)
./build.sh           # release app bundle in build/FaceUnlock.app
./release.sh         # zip + SHA-256 in dist/ (notarises only if configured)
```

`build.sh` signs **ad-hoc** by default. To sign local builds with your own
identity, copy `signing.local.env.example` to `signing.local.env` (git-ignored)
and set `FACEUNLOCK_SIGN_ID` to a hash from
`security find-identity -v -p codesigning`, or export `FACEUNLOCK_SIGN_ID` in
your shell. With a stable identity, Keychain access and the
Camera/Accessibility grants survive rebuilds; with ad-hoc signing they have to
be granted again after every build. `release.sh` only notarises when you've
explicitly chosen a Developer ID Application identity and set
`FACEUNLOCK_NOTARY_PROFILE`.

Never run the unlock flow against your own lock screen from a debugger
session you can't interrupt, and never commit diagnostics logs.

## Code layout

| Path | What |
| --- | --- |
| `Sources/FaceUnlockCore/` | Pure, unit-tested logic: matching, liveness (blink, pose, natural movement), lockout, scan policy, setup gating, attempt records, diagnostics summaries, plus the Vision/Core ML face pipeline and template storage. No AppKit. |
| `Sources/FaceUnlock/` | The menu-bar app: camera, lock-session coordinator, Keychain, password verification (OpenDirectory), keystroke typing, lock-screen HUD, Setup window. |
| `Tests/FaceUnlockCoreTests/` | Swift Testing suites, including a Core ML parity test against a reference embedding. |
| `Models/SFace.mlpackage` | The face-embedding model (Apache-2.0, see NOTICE). |
| `tools/convert_sface.py` | Re-creates the model from OpenCV Zoo's ONNX file, with a parity check. |
| `Resources/` | Info.plist and entitlements. |

### About the model file

`Models/SFace.mlpackage` is about 18 MB. That is well under GitHub's 100 MB
per-file limit, so it is committed to plain git and **Git LFS is not used**.
If you regenerate it, run `tools/convert_sface.py` (it refuses to write the
model unless the Core ML output matches the original ONNX model) and mention
it in the PR.

## Pull requests

- Keep changes focused; one topic per PR.
- `swift build`, `swift test` and `./build.sh` must pass with **no warnings**.
- Add or update unit tests for logic changes. Logic that can be pure belongs
  in `FaceUnlockCore` so it can be tested.
- Explain the security impact of anything that touches matching, liveness,
  lockout, the Keychain, typing, or when the camera runs.
- Never log or persist the password, embeddings or images.
- No network access: FaceUnlock must keep working fully offline.
- Update `README.md` and `CHANGELOG.md` when behaviour changes.
