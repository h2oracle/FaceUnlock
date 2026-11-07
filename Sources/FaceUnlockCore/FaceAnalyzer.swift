import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

/// Everything extracted from one camera frame.
public struct FrameAnalysis: @unchecked Sendable {
    public var faceCount: Int
    /// Normalised (0–1, lower-left origin) bounding box of the single face.
    public var boundingBox: CGRect?
    public var yawDegrees: Double?
    public var pitchDegrees: Double?
    public var rollDegrees: Double?
    /// VNDetectFaceCaptureQualityRequest score (0–1), only when requested.
    public var captureQuality: Float?
    public var leftEyeOpenness: Double?
    public var rightEyeOpenness: Double?
    public var faceShape: Double?
    /// 112×112 face aligned to the ArcFace/SFace 5-point template.
    public var alignedFace: CGImage?
    public var embedding: [Float]?

    public static let none = FrameAnalysis(faceCount: 0)

    public init(faceCount: Int) { self.faceCount = faceCount }

    public func eyeSample(at time: TimeInterval) -> EyeSample? {
        guard let l = leftEyeOpenness, let r = rightEyeOpenness, let s = faceShape else { return nil }
        return EyeSample(time: time, left: l, right: r, faceShape: s, pitch: pitchDegrees)
    }
}

/// Vision-based face detection, landmarks, pose, quality and alignment,
/// followed by the Core ML embedding. Stateless apart from the shared
/// CIContext/model, so it can be used from any one queue at a time.
public final class FaceAnalyzer: @unchecked Sendable {
    /// Faces narrower than this fraction of the frame are ignored entirely
    /// (distant background detections), but anything larger counts towards
    /// the "exactly one face" rule.
    public static let minimumFaceWidth: CGFloat = 0.06

    /// Canonical 5-point template for 112×112 crops (top-left origin):
    /// image-left eye, image-right eye, nose tip, image-left / -right mouth corner.
    static let template: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963),
        CGPoint(x: 73.5318, y: 51.5014),
        CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655),
        CGPoint(x: 70.7299, y: 92.2041),
    ]

    private let embedder: FaceEmbedder?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    public init(embedder: FaceEmbedder?) {
        self.embedder = embedder
    }

    public func analyze(pixelBuffer: CVPixelBuffer, wantQuality: Bool = false) -> FrameAnalysis {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        return analyze(image: image, handler: handler, wantQuality: wantQuality)
    }

    public func analyze(cgImage: CGImage, wantQuality: Bool = false) -> FrameAnalysis {
        let image = CIImage(cgImage: cgImage)
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        return analyze(image: image, handler: handler, wantQuality: wantQuality)
    }

    private func analyze(image: CIImage, handler: VNImageRequestHandler, wantQuality: Bool) -> FrameAnalysis {
        let rectangles = VNDetectFaceRectanglesRequest()
        rectangles.revision = VNDetectFaceRectanglesRequestRevision3
        do { try handler.perform([rectangles]) } catch { return .none }

        let faces = (rectangles.results ?? []).filter { $0.boundingBox.width >= Self.minimumFaceWidth }
        var result = FrameAnalysis(faceCount: faces.count)
        guard faces.count == 1, let face = faces.first else { return result }

        result.boundingBox = face.boundingBox
        result.yawDegrees = face.yaw.map { $0.doubleValue * 180 / .pi }
        result.pitchDegrees = face.pitch.map { $0.doubleValue * 180 / .pi }
        result.rollDegrees = face.roll.map { $0.doubleValue * 180 / .pi }

        let landmarksRequest = VNDetectFaceLandmarksRequest()
        landmarksRequest.inputFaceObservations = [face]
        var requests: [VNRequest] = [landmarksRequest]
        var qualityRequest: VNDetectFaceCaptureQualityRequest?
        if wantQuality {
            let q = VNDetectFaceCaptureQualityRequest()
            q.inputFaceObservations = [face]
            qualityRequest = q
            requests.append(q)
        }
        do { try handler.perform(requests) } catch { return result }

        result.captureQuality = qualityRequest?.results?.first?.faceCaptureQuality

        guard let observation = landmarksRequest.results?.first,
              let landmarks = observation.landmarks else { return result }
        let size = image.extent.size
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            region?.pointsInImage(imageSize: size) ?? []
        }

        let leftEye = points(landmarks.leftEye), rightEye = points(landmarks.rightEye)
        result.leftEyeOpenness = LandmarkGeometry.eyeOpenness(leftEye)
        result.rightEyeOpenness = LandmarkGeometry.eyeOpenness(rightEye)

        // Eye centres: pupil if Vision found one, else contour centroid.
        guard let eyeA = points(landmarks.leftPupil).first ?? LandmarkGeometry.centroid(leftEye),
              let eyeB = points(landmarks.rightPupil).first ?? LandmarkGeometry.centroid(rightEye) else { return result }
        let lips = points(landmarks.outerLips)
        guard let mouth = LandmarkGeometry.centroid(lips),
              let nose = LandmarkGeometry.centroid(points(landmarks.nose)),
              let mouthLeft = lips.min(by: { $0.x < $1.x }),
              let mouthRight = lips.max(by: { $0.x < $1.x }) else { return result }
        result.faceShape = LandmarkGeometry.faceShape(leftEye: eyeA, rightEye: eyeB, mouth: mouth)

        // Vision's left/right are anatomical; the template is by image position.
        let imageLeftEye = eyeA.x <= eyeB.x ? eyeA : eyeB
        let imageRightEye = eyeA.x <= eyeB.x ? eyeB : eyeA
        let source = [imageLeftEye, imageRightEye, nose, mouthLeft, mouthRight]

        guard let aligned = align(image: image, sourcePoints: source) else { return result }
        result.alignedFace = aligned
        if let embedder {
            result.embedding = try? embedder.embedding(for: aligned)
        }
        return result
    }

    /// Warps the face onto the 112×112 template. Vision points and CIImage
    /// share a lower-left origin; the template is flipped to match.
    private func align(image: CIImage, sourcePoints: [CGPoint]) -> CGImage? {
        let side = CGFloat(FaceEmbedder.inputSize)
        let destination = Self.template.map { CGPoint(x: $0.x, y: side - $0.y) }
        guard let transform = LandmarkGeometry.similarityTransform(from: sourcePoints, to: destination) else { return nil }
        let warped = image
            .clampedToExtent()
            .transformed(by: transform, highQualityDownsample: true)
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        return ciContext.createCGImage(warped, from: CGRect(x: 0, y: 0, width: side, height: side))
    }
}
