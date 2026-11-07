import CoreGraphics
import Foundation
@testable import FaceUnlockCore

/// Physically based synthetic landmarks: a 3D face model (real head) or the
/// same landmarks on a flat plane (a photo), projected through a pinhole
/// camera under head/photo motion, with Gaussian landmark noise.
/// Units: inter-ocular distance (IOD) = 1; x right, y up, z towards camera.
struct SyntheticFace {
    static let model: [SIMD3<Double>] = {
        var p: [SIMD3<Double>] = []
        for side in [-1.0, 1.0] {
            // Eye contour (8 points), slightly recessed.
            for k in 0..<8 {
                let a = Double(k) / 8 * 2 * .pi
                p.append([side * 0.5 + 0.17 * cos(a), 0.06 * sin(a), -0.05])
            }
            // Brow (4 points).
            for k in 0..<4 { p.append([side * (0.25 + 0.18 * Double(k)), 0.27 + 0.02 * Double(k % 2), 0.05]) }
            // Nostril, mouth corner, mid-lips.
            p.append([side * 0.17, -0.68, 0.35])
            p.append([side * 0.40, -1.05, 0.12])
            p.append([side * 0.20, -0.97, 0.25])
            p.append([side * 0.20, -1.13, 0.22])
            // Jaw contour (4 points per side).
            p.append([side * 1.00, -0.20, -0.75])
            p.append([side * 0.95, -0.70, -0.60])
            p.append([side * 0.80, -1.15, -0.35])
            p.append([side * 0.50, -1.50, -0.10])
        }
        // Midline: nose bridge, mid nose, tip, base; lips; chin.
        p += [[0, -0.15, 0.25], [0, -0.35, 0.40], [0, -0.60, 0.55], [0, -0.72, 0.38],
              [0, -0.98, 0.30], [0, -1.15, 0.27], [0, -1.65, 0.05]]
        return p
    }()

    struct Pose {
        var yaw = 0.0, pitch = 0.0, roll = 0.0 // degrees
        var tx = 0.0, ty = 0.0, distance = 8.0 // IOD units (≈50 cm)
    }

    var flat: Bool
    var noise: Double // landmark noise, fraction of IOD
    var poseNoise = 0.7 // reported yaw/pitch noise, degrees
    private var rng: UInt64

    init(flat: Bool, noise: Double = 0.015, seed: UInt64 = 1) {
        self.flat = flat
        self.noise = noise
        self.rng = seed &* 0x9E3779B97F4A7C15 | 1
    }

    private mutating func gaussian() -> Double {
        func uniform() -> Double {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return (Double(rng >> 11) + 0.5) / Double(1 << 53)
        }
        return (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform())
    }

    /// One frame: noisy projected landmarks, IOD in pixels and the reported pose.
    mutating func frame(time: TimeInterval, pose: Pose, score: Float = 0.9) -> FrameObservation {
        let f = 600.0
        let (y, x, z) = (pose.yaw * .pi / 180, pose.pitch * .pi / 180, pose.roll * .pi / 180)
        func rotate(_ v: SIMD3<Double>) -> SIMD3<Double> {
            // yaw (about y), then pitch (about x), then roll (about z)
            var r = SIMD3(cos(y) * v.x + sin(y) * v.z, v.y, -sin(y) * v.x + cos(y) * v.z)
            r = SIMD3(r.x, cos(x) * r.y - sin(x) * r.z, sin(x) * r.y + cos(x) * r.z)
            return SIMD3(cos(z) * r.x - sin(z) * r.y, sin(z) * r.x + cos(z) * r.y, r.z)
        }
        func project(_ m: SIMD3<Double>) -> CGPoint {
            let local = SIMD3(m.x, m.y, flat ? 0 : m.z)
            let c = rotate(local)
            // Camera looks along -z of the face: depth = distance - z.
            let depth = pose.distance - c.z
            return CGPoint(x: f * (c.x + pose.tx) / depth, y: f * (c.y + pose.ty) / depth)
        }
        let iodPixels = f / pose.distance
        let points = Self.model.map { m -> CGPoint in
            let p = project(m)
            return CGPoint(x: p.x + gaussian() * noise * iodPixels, y: p.y + gaussian() * noise * iodPixels)
        }
        let eyes = 0.10
        return FrameObservation(
            time: time, faceCount: 1, score: MatchScore(centroid: score, bestSample: score),
            eyes: EyeSample(time: time, left: eyes, right: eyes, faceShape: 1.2, pitch: pose.pitch),
            yawDegrees: pose.yaw + gaussian() * poseNoise, pitchDegrees: pose.pitch + gaussian() * poseNoise,
            landmarks: points, interocular: iodPixels)
    }
}
