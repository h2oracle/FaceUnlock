import AVFoundation
import CoreVideo
import Foundation

/// Owns the AVCaptureSession for the built-in camera. Frames are handed to a
/// single handler on `videoQueue`; nothing is ever written to disk.
/// Only one consumer (enrolment, test window or unlock attempt) at a time.
final class CameraSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    typealias FrameHandler = @Sendable (CVPixelBuffer, TimeInterval) -> Void

    enum CameraError: Error, CustomStringConvertible {
        case notAuthorized
        case noCamera
        case configurationFailed

        var description: String {
            switch self {
            case .notAuthorized: return "Camera access has not been granted."
            case .noCamera: return "The enrolled built-in camera is not available."
            case .configurationFailed: return "Could not configure the camera."
            }
        }
    }

    let session = AVCaptureSession()
    let videoQueue = DispatchQueue(label: "uk.co.sid.faceunlock.video", qos: .userInitiated)
    private let sessionQueue = DispatchQueue(label: "uk.co.sid.faceunlock.camera")
    private let output = AVCaptureVideoDataOutput()
    private var configured = false

    private let lock = NSLock()
    private var handler: FrameHandler?
    private var lastFrameTime: TimeInterval = 0
    /// Frames beyond this rate are dropped before any processing. Frames
    /// that arrive while the previous one is still being processed are
    /// dropped by AVFoundation (`alwaysDiscardsLateVideoFrames`), never queued.
    private let maximumFPS: Double = 31

    /// Built-in Apple cameras only: no external/USB, Continuity (iPhone),
    /// Desk View or virtual (software) cameras.
    static func isAllowed(_ device: AVCaptureDevice) -> Bool {
        device.deviceType == .builtInWideAngleCamera
            && !device.isContinuityCamera
            && device.manufacturer == "Apple Inc."
    }

    static func builtInCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
            .devices.filter(isAllowed)
    }

    /// The camera with `uniqueID` if it is an allowed built-in camera, or the
    /// first built-in camera when `uniqueID` is nil (enrolment).
    static func device(uniqueID: String?) -> AVCaptureDevice? {
        let cameras = builtInCameras()
        guard let uniqueID else { return cameras.first }
        return cameras.first { $0.uniqueID == uniqueID }
    }

    private var currentInput: AVCaptureDeviceInput?

    private func configure(device: AVCaptureDevice) throws {
        if configured, currentInput?.device.uniqueID == device.uniqueID { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if let currentInput { session.removeInput(currentInput) }
        currentInput = nil
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else {
            session.sessionPreset = .high
        }
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            throw CameraError.configurationFailed
        }
        session.addInput(input)
        currentInput = input
        // Allow up to 30 fps (auto-exposure may still lower it in dim light).
        if (try? device.lockForConfiguration()) != nil {
            let wanted = CMTime(value: 1, timescale: 30)
            if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameDuration >= wanted && $0.minFrameDuration <= wanted }) {
                device.activeVideoMinFrameDuration = wanted
            }
            device.unlockForConfiguration()
        }
        if !configured {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: videoQueue)
            guard session.canAddOutput(output) else { throw CameraError.configurationFailed }
            session.addOutput(output)
            configured = true
        }
    }

    /// Starts `device` and routes frames to `handler`. Never prompts for
    /// permission: callers must check/request authorisation beforehand.
    func start(device: AVCaptureDevice, handler: @escaping FrameHandler, completion: @escaping @Sendable (Error?) -> Void) {
        guard Permissions.cameraAuthorized else {
            completion(CameraError.notAuthorized)
            return
        }
        guard Self.isAllowed(device) else {
            completion(CameraError.noCamera)
            return
        }
        nonisolated(unsafe) let device = device
        lock.withLock {
            self.handler = handler
            self.lastFrameTime = 0
        }
        sessionQueue.async { [self] in
            do {
                try configure(device: device)
                if !session.isRunning { session.startRunning() }
                completion(nil)
            } catch {
                lock.withLock { self.handler = nil }
                completion(error)
            }
        }
    }

    /// Configures inputs/outputs for `device` without starting the camera
    /// (no camera light), so a later `start` only has to call startRunning.
    func prepare(device: AVCaptureDevice) {
        guard Permissions.cameraAuthorized, Self.isAllowed(device) else { return }
        nonisolated(unsafe) let device = device
        sessionQueue.async { [self] in try? configure(device: device) }
    }

    /// Stops the camera (the green light goes off) and detaches the handler.
    func stop() {
        lock.withLock { handler = nil }
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let current: FrameHandler? = lock.withLock {
            guard let handler, now - lastFrameTime >= 1 / maximumFPS else { return nil }
            lastFrameTime = now
            return handler
        }
        current?(pixelBuffer, now)
    }
}
