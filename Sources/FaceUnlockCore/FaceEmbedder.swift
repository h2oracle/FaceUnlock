import CoreGraphics
import CoreML
import CoreVideo
import Foundation

public enum FaceEmbedderError: Error, CustomStringConvertible {
    case modelMissing
    case badOutput(String)

    public var description: String {
        switch self {
        case .modelMissing: return "SFace.mlmodelc is missing from the app bundle. Rebuild with ./build.sh."
        case .badOutput(let s): return "Face model returned unexpected output: \(s)"
        }
    }
}

/// SFace (OpenCV Zoo, Apache-2.0): MobileFaceNet backbone, 112×112 aligned
/// RGB face in, 128-d embedding out. Normalisation is inside the model.
public final class FaceEmbedder: @unchecked Sendable {
    public static let modelID = "sface-2021dec-v1"
    public static let inputSize = 112
    public static let dimension = 128

    private let model: MLModel
    private let lock = NSLock()

    /// `compiledModelURL` must point at a compiled `.mlmodelc` directory.
    public init(compiledModelURL: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        model = try MLModel(contentsOf: compiledModelURL, configuration: config)
    }

    /// Loads `SFace.mlmodelc` from the given bundle (the app bundle by default).
    public convenience init(bundle: Bundle = .main) throws {
        guard let url = bundle.url(forResource: "SFace", withExtension: "mlmodelc") else {
            throw FaceEmbedderError.modelMissing
        }
        try self.init(compiledModelURL: url)
    }

    /// Returns an L2-normalised 128-d embedding for a 112×112 aligned face.
    public func embedding(for face: CGImage) throws -> [Float] {
        let input = try MLFeatureValue(
            cgImage: face,
            pixelsWide: Self.inputSize,
            pixelsHigh: Self.inputSize,
            pixelFormatType: kCVPixelFormatType_32BGRA,
            options: nil
        )
        return try embedding(input: input)
    }

    /// Faster path: a 112×112 32BGRA pixel buffer (no CGImage conversion).
    public func embedding(for pixelBuffer: CVPixelBuffer) throws -> [Float] {
        try embedding(input: MLFeatureValue(pixelBuffer: pixelBuffer))
    }

    /// Runs one throw-away inference so the first real frame doesn't pay
    /// for Core ML's lazy model loading / Neural Engine set-up.
    public func prewarm() {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, Self.inputSize, Self.inputSize, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary, &buffer)
        if let buffer { _ = try? embedding(for: buffer) }
    }

    private func embedding(input: MLFeatureValue) throws -> [Float] {
        let provider = try MLDictionaryFeatureProvider(dictionary: ["image": input])
        let output: MLFeatureProvider = try lock.withLock { try model.prediction(from: provider) }
        guard let array = output.featureValue(for: "embedding")?.multiArrayValue else {
            throw FaceEmbedderError.badOutput("no 'embedding' output")
        }
        guard array.count == Self.dimension else {
            throw FaceEmbedderError.badOutput("expected \(Self.dimension) values, got \(array.count)")
        }
        var values = [Float](repeating: 0, count: array.count)
        for i in 0..<array.count { values[i] = array[i].floatValue }
        return VectorMath.l2Normalized(values)
    }
}
