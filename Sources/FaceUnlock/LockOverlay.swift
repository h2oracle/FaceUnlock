import AppKit
import SwiftUI

/// An iPhone Face ID-style HUD shown on the lock screen while scanning:
/// a frosted rounded square with a pulsing face glyph ("Looking for you…"),
/// a drawn circle + checkmark on a match, and a shake with "Face Not
/// Recognised" on a failed look.
///
/// Purely cosmetic and fail-safe: every step is best effort, nothing here can
/// block or delay unlocking, and the panel never takes focus, keys or clicks
/// (the lock screen's password field keeps keyboard focus).
@MainActor
final class LockOverlay {
    private let model = HUDModel()
    private var panel: OverlayPanel?
    private var delegatedToLockScreen = false
    private var pending: DispatchWorkItem?

    func showScanning() {
        cancelPending()
        model.hint = nil
        model.phase = .scanning
        model.visible = true
        present()
    }

    /// Fades the HUD out (e.g. nobody in view) or back in.
    func setVisible(_ visible: Bool) {
        guard model.phase == .scanning, model.visible != visible else { return }
        model.visible = visible
    }

    /// Match: circle + checkmark draw in; typing runs in parallel.
    func showSuccess() {
        cancelPending()
        model.visible = true
        model.phase = .success
        present()
        after(1.6) { $0.hide() }
    }

    /// A failed look while scanning continues: shake, caption, back to scanning.
    func flashFailure(_ message: String = "Face Not Recognised") {
        cancelPending()
        model.failureText = message
        model.visible = true
        model.phase = .failure
        present()
        after(1.3) { overlay in
            guard overlay.model.phase == .failure else { return }
            overlay.model.phase = .scanning
        }
    }

    func flashFailureAndHide() {
        cancelPending()
        model.failureText = "Face Not Recognised"
        model.visible = true
        model.phase = .failure
        present()
        after(1.5) { $0.hide() }
    }

    /// While scanning: a short instruction instead of "Looking for you…".
    func setHint(_ hint: String?) {
        guard model.hint != hint else { return }
        model.hint = hint
    }

    /// Scanning has stopped for this lock session.
    func showStopped(_ message: String) {
        cancelPending()
        model.stoppedText = "Face Not Recognised\n" + message
        model.visible = true
        model.phase = .stopped
        present()
        after(4) { $0.hide() }
    }

    func hide() {
        cancelPending()
        model.visible = false
        guard let panel else { return }
        if delegatedToLockScreen {
            LockScreenSpace.shared?.remove(panel)
            delegatedToLockScreen = false
        }
        panel.orderOut(nil)
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    private func after(_ seconds: TimeInterval, _ body: @escaping @MainActor (LockOverlay) -> Void) {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                body(self)
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private static let panelSize = NSSize(width: 220, height: 220)

    private func present() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Same spot as before: centred horizontally, its centre at ~42 % of
        // the screen height + 80 pt (above the user picture and password field).
        let frame = screen.frame
        let center = NSPoint(x: frame.midX, y: frame.minY + frame.height * 0.42 + 80)
        panel.setFrameOrigin(NSPoint(x: center.x - Self.panelSize.width / 2, y: center.y - Self.panelSize.height / 2))
        panel.orderFrontRegardless()
        if !delegatedToLockScreen, SessionState.current().screenLocked, let space = LockScreenSpace.shared {
            space.add(panel)
            delegatedToLockScreen = true
        }
    }

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
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
        panel.appearance = NSAppearance(named: .darkAqua)
        // Above the lock screen's shielding window.
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.canBecomeVisibleWithoutLogin = true
        let host = NSHostingView(rootView: HUDView(model: model))
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
private final class HUDModel {
    enum Phase { case scanning, success, failure, stopped }
    var phase: Phase = .scanning
    var visible = false
    var failureText = "Face Not Recognised"
    var stoppedText = "Face Not Recognised\nUse your password"
    var hint: String?
}

/// Frosted HUD background (.hudWindow material, dark, rounded corners).
private struct HUDBackground: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        view.maskImage = Self.mask(radius: cornerRadius)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}

    /// Resizable rounded-rect mask (the standard way to round a visual effect view).
    private static func mask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.52))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.67))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.73, y: rect.minY + rect.height * 0.36))
        return p
    }
}

/// Horizontal wrong-passcode shake.
private struct Shake: GeometryEffect {
    var travel: CGFloat = 9
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(animatableData * .pi * 6), y: 0))
    }
}

private struct HUDView: View {
    let model: HUDModel
    @State private var circle: CGFloat = 0
    @State private var check: CGFloat = 0
    @State private var bounce: CGFloat = 1
    @State private var shake: CGFloat = 0

    private let green = Color(red: 0.2, green: 0.85, blue: 0.4)

    var body: some View {
        ZStack {
            HUDBackground(cornerRadius: 28)
            VStack(spacing: 10) {
                ZStack {
                    Image(systemName: "faceid")
                        .font(.system(size: 72, weight: .light))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, options: .repeating, isActive: model.phase == .scanning)
                        .opacity(model.phase == .success ? 0 : 1)
                        .scaleEffect(model.phase == .success ? 0.6 : 1)
                        .modifier(Shake(animatableData: shake))
                    Circle()
                        .trim(from: 0, to: circle)
                        .stroke(green, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 76, height: 76)
                    CheckmarkShape()
                        .trim(from: 0, to: check)
                        .stroke(green, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                        .frame(width: 76, height: 76)
                }
                .frame(width: 84, height: 84)
                .scaleEffect(bounce)
                Text(caption)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .frame(height: 30)
            }
            .padding(.top, 12)
        }
        .frame(width: 160, height: 160)
        .frame(width: 220, height: 220)
        .opacity(model.visible ? 1 : 0)
        .animation(.easeInOut(duration: 0.35), value: model.visible)
        .animation(.easeOut(duration: 0.15), value: model.phase)
        .task(id: model.phase) { await run(model.phase) }
    }

    private var caption: String {
        switch model.phase {
        case .scanning: return model.hint ?? "Looking for you…"
        case .success: return ""
        case .failure: return model.failureText
        case .stopped: return model.stoppedText
        }
    }

    private func run(_ phase: HUDModel.Phase) async {
        switch phase {
        case .success:
            circle = 0; check = 0; bounce = 1
            withAnimation(.easeOut(duration: 0.2)) { circle = 1 }
            try? await Task.sleep(for: .milliseconds(170))
            withAnimation(.easeOut(duration: 0.17)) { check = 1 }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.45)) { bounce = 1.08 }
            try? await Task.sleep(for: .milliseconds(160))
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { bounce = 1 }
        case .failure, .stopped:
            circle = 0; check = 0; bounce = 1
            shake = 0
            withAnimation(.linear(duration: 0.45)) { shake = 1 }
        case .scanning:
            circle = 0; check = 0; bounce = 1; shake = 0
        }
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
