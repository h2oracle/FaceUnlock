// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FaceUnlock",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "FaceUnlock", targets: ["FaceUnlock"]),
    ],
    targets: [
        // Pure logic + Vision/Core ML face pipeline. No AppKit, no UI, no I/O
        // beyond the template file, so it can be unit-tested headlessly.
        .target(
            name: "FaceUnlockCore",
            path: "Sources/FaceUnlockCore"
        ),
        // The menu-bar app: camera, lock monitoring, Keychain, keystrokes, UI.
        .executableTarget(
            name: "FaceUnlock",
            dependencies: ["FaceUnlockCore"],
            path: "Sources/FaceUnlock"
        ),
        .testTarget(
            name: "FaceUnlockCoreTests",
            dependencies: ["FaceUnlockCore"],
            path: "Tests/FaceUnlockCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
