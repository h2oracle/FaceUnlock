import AppKit
import SwiftUI

/// A small Face ID-style indicator shown on the lock screen while an attempt
/// runs: scanning ring, filling progress ring, green tick on a match, and a
/// short "Face not recognised" on failure.
///
/// Purely cosmetic and fail-safe: every step is best effort, nothing here can
/// block or delay unlocking, and the panel never takes focus, keys or clicks
/// (the lock screen's password field keeps keyboard focus).
@MainActor
final class LockOverlay {
    private let model = OverlayModel()
    private var panel: OverlayPanel?
    private var delegatedToLockScreen = false
    private var hideWork: DispatchWorkItem?

    func showScanning() {
        hideWork?.cancel()
        model.phase = .scanning
        model.progress = 0
        present()
    }

    func update(progress: Double) {
        guard model.phase == .scanning else { return }
        model.progress = max(0, min(1, progress))
    }

    func showSuccess() {
        hideWork?.cancel()
        model.phase = .success
        model.progress = 1
        present()
        scheduleHide(after: 2)
    }

    func showFailure() {
        hideWork?.cancel()
        model.phase = .failure
        present()
        scheduleHide(after: 1.6)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        guard let panel else { return }
        if delegatedToLockScreen {
            LockScreenSpace.shared?.remove(panel)
            delegatedToLockScreen = false
        }
        panel.orderOut(nil)
    }

    private func scheduleHide(after seconds: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func present() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = panel.frame.size
        // Centred horizontally, above the lock screen's user picture and
        // password field (which sit in the lower part of the screen).
        let frame = screen.frame
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.42)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        if !delegatedToLockScreen, SessionState.current().screenLocked, let space = LockScreenSpace.shared {
            space.add(panel)
            delegatedToLockScreen = true
        }
    }

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        // Above the lock screen's shielding window.
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.canBecomeVisibleWithoutLogin = true
        let host = NSHostingView(rootView: OverlayView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }
}

/// Never key, never main: it must not steal the password field's focus.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
@Observable
private final class OverlayModel {
    enum Phase { case scanning, success, failure }
    var phase: Phase = .scanning
    var progress = 0.0
}

private struct OverlayView: View {
    let model: OverlayModel

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(.ultraThinMaterial)
                switch model.phase {
                case .scanning:
                    Circle().stroke(.white.opacity(0.25), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: max(0.02, model.progress))
                        .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.25), value: model.progress)
                    TimelineView(.animation) { context in
                        let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360
                        Circle()
                            .trim(from: 0, to: 0.15)
                            .stroke(.white.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .padding(9)
                            .rotationEffect(.degrees(angle))
                    }
                    Image(systemName: "faceid").font(.system(size: 34, weight: .light)).foregroundStyle(.white)
                case .success:
                    Circle().stroke(.green, lineWidth: 4)
                    Image(systemName: "checkmark").font(.system(size: 36, weight: .semibold)).foregroundStyle(.green)
                case .failure:
                    Circle().stroke(.white.opacity(0.4), lineWidth: 4)
                    Image(systemName: "faceid").font(.system(size: 34, weight: .light)).foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(width: 88, height: 88)
            Text(model.phase == .failure ? "Face not recognised" : " ")
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .shadow(radius: 3)
        }
        .frame(width: 240, height: 160)
    }
}

/// Makes a window visible above the macOS lock screen by moving it into a
/// window-server "space" at the level Notification Center uses while the
/// screen is locked. Uses private SkyLight functions looked up at run time
/// (technique learned from Glance and Lakr233/SkyLightWindow, both MIT – see
/// NOTICE). `shared` is nil if anything is missing, in which case the
/// overlay simply isn't visible on the lock screen.
@MainActor
final class LockScreenSpace {
    static let shared: LockScreenSpace? = LockScreenSpace()

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
    private typealias RemoveWindows = @convention(c) (Int32, CFArray, CFArray) -> Int32

    /// Notification Center's level on the lock screen.
    private static let lockScreenLevel: Int32 = 400

    private let connection: Int32
    private let space: Int32
    private let addWindows: AddWindows
    private let removeWindows: RemoveWindows

    private init?() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
        guard let handle = dlopen(path, RTLD_NOW),
              let mainSym = dlsym(handle, "SLSMainConnectionID"),
              let createSym = dlsym(handle, "SLSSpaceCreate"),
              let levelSym = dlsym(handle, "SLSSpaceSetAbsoluteLevel"),
              let showSym = dlsym(handle, "SLSShowSpaces"),
              let addSym = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces"),
              let removeSym = dlsym(handle, "SLSRemoveWindowsFromSpaces") else { return nil }
        let main = unsafeBitCast(mainSym, to: MainConnection.self)
        let create = unsafeBitCast(createSym, to: SpaceCreate.self)
        let setLevel = unsafeBitCast(levelSym, to: SpaceSetLevel.self)
        let show = unsafeBitCast(showSym, to: ShowSpaces.self)
        addWindows = unsafeBitCast(addSym, to: AddWindows.self)
        removeWindows = unsafeBitCast(removeSym, to: RemoveWindows.self)

        connection = main()
        // Flag 1 is what makes it an overlay-only space (other values let
        // Finder draw desktop icons into it).
        space = create(connection, 1, 0)
        guard space != 0 else { return nil }
        _ = setLevel(connection, space, Self.lockScreenLevel)
        _ = show(connection, [space] as CFArray)
    }

    func add(_ window: NSWindow) {
        _ = addWindows(connection, space, [window.windowNumber] as CFArray, 7)
    }

    func remove(_ window: NSWindow) {
        _ = removeWindows(connection, [window.windowNumber] as CFArray, [space] as CFArray)
    }
}
