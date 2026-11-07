import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation
import ImageIO
import Testing
@testable import FaceUnlockCore

@Suite struct EmbedderParityTests {
    /// Compiles Models/SFace.mlpackage and checks the Swift path (CGImage ->
    /// Core ML) reproduces the reference ONNX embedding for a fixture image.
    /// Catches RGB/BGR or scaling mistakes, which still "work" but silently
    /// destroy accuracy (BGR input gives cosine ≈ 0.77 on this fixture).
    @Test func swiftEmbeddingMatchesOnnxReference() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let package = repoRoot.appendingPathComponent("Models/SFace.mlpackage")
        try #require(FileManager.default.fileExists(atPath: package.path), "missing \(package.path)")
        let compiled = try MLModel.compileModel(at: package)
        defer { try? FileManager.default.removeItem(at: compiled) }
        let embedder = try FaceEmbedder(compiledModelURL: compiled)

        let fixtures = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let source = try #require(CGImageSourceCreateWithURL(fixtures.appendingPathComponent("pattern112.png") as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        struct Reference: Decodable { let embedding: [Float] }
        let reference = try JSONDecoder().decode(
            Reference.self, from: Data(contentsOf: fixtures.appendingPathComponent("pattern112.embedding.json")))

        let embedding = try embedder.embedding(for: image)
        #expect(embedding.count == FaceEmbedder.dimension)
        let cosine = VectorMath.cosine(embedding, reference.embedding)
        #expect(cosine > 0.98, "cosine to ONNX reference was \(cosine)")

        // Fast path used for camera frames: render into a BGRA pixel buffer.
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 112, 112, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary, &buffer)
        let pixelBuffer = try #require(buffer)
        CIContext().render(CIImage(cgImage: image), to: pixelBuffer, bounds: CGRect(x: 0, y: 0, width: 112, height: 112),
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let fast = try embedder.embedding(for: pixelBuffer)
        let fastCosine = VectorMath.cosine(fast, reference.embedding)
        #expect(fastCosine > 0.98, "pixel-buffer path cosine was \(fastCosine)")
    }
}

@Suite struct TemplateStoreTests {
    @Test func savesWithPrivatePermissionsAndRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("faceunlock-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TemplateStore(directory: dir)
        #expect(store.load() == nil)

        let template = try FaceTemplate(modelID: "m", samples: [[1, 0], [0.9, 0.1]], cameraID: "cam-1")
        try store.save(template)
        let digest = try store.save(template) // overwrite path
        let loaded = try #require(store.loadWithDigest())
        #expect(loaded.sha256 == digest)
        #expect(loaded.template.cameraID == "cam-1")
        #expect(digest == TemplateStore.sha256Hex(try Data(contentsOf: store.fileURL)))

        // Any edit to the file changes the digest.
        var bytes = try Data(contentsOf: store.fileURL)
        bytes.append(contentsOf: Array(" ".utf8))
        try bytes.write(to: store.fileURL)
        #expect(store.loadWithDigest()?.sha256 != digest)
        try store.save(template)

        let fileMode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        let dirMode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(fileMode == 0o600)
        #expect(dirMode == 0o700)
        #expect(store.load() == template)

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(leftovers == ["face-template.json"])

        try store.delete()
        #expect(store.load() == nil)
    }
}

@Suite struct EnrolmentCollectorTests {
    private func good(_ embedding: [Float] = [1, 0]) -> FrameAnalysis {
        var f = FrameAnalysis(faceCount: 1)
        f.captureQuality = 0.8
        f.embedding = embedding
        return f
    }

    @Test func rejectsBadFramesAndWalksThroughSteps() {
        var c = EnrolmentCollector()
        var t = 0.0
        let settling = c.offer(good(), at: t) // settle period starts
        #expect(!settling)
        t += 2
        var bad = good(); bad.captureQuality = 0.1
        let acceptedBad = c.offer(bad, at: t)
        #expect(!acceptedBad)
        #expect(c.lastRejection != nil)
        var two = good(); two.faceCount = 2
        let acceptedTwo = c.offer(two, at: t)
        #expect(!acceptedTwo)

        var steps = Set<String>()
        while !c.isComplete && t < 100 {
            steps.insert(c.currentInstruction)
            c.offer(good(), at: t)
            t += 0.25
        }
        #expect(c.isComplete)
        #expect(c.embeddings.count == c.totalRequired)
        #expect(steps.count == EnrolmentCollector.steps.count)
    }
}
