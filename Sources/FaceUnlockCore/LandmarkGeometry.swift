import CoreGraphics
import Foundation

/// Plain geometry on landmark points; no Vision types so it's easy to test.
public enum LandmarkGeometry {
    /// Least-squares 2D similarity transform (rotation, uniform scale,
    /// translation; no reflection/shear) mapping `source` onto `destination`.
    public static func similarityTransform(from source: [CGPoint], to destination: [CGPoint]) -> CGAffineTransform? {
        guard source.count == destination.count, source.count >= 2 else { return nil }
        let n = CGFloat(source.count)
        let sMean = CGPoint(x: source.map(\.x).reduce(0, +) / n, y: source.map(\.y).reduce(0, +) / n)
        let dMean = CGPoint(x: destination.map(\.x).reduce(0, +) / n, y: destination.map(\.y).reduce(0, +) / n)

        var num1: CGFloat = 0, num2: CGFloat = 0, den: CGFloat = 0
        for (s, d) in zip(source, destination) {
            let sx = s.x - sMean.x, sy = s.y - sMean.y
            let dx = d.x - dMean.x, dy = d.y - dMean.y
            num1 += sx * dx + sy * dy
            num2 += sx * dy - sy * dx
            den += sx * sx + sy * sy
        }
        guard den > .ulpOfOne else { return nil }
        let a = num1 / den, b = num2 / den
        let tx = dMean.x - (a * sMean.x - b * sMean.y)
        let ty = dMean.y - (b * sMean.x + a * sMean.y)
        guard a.isFinite, b.isFinite, tx.isFinite, ty.isFinite else { return nil }
        return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)
    }

    /// Scale/rotation-invariant openness of an eye contour: polygon area
    /// divided by the squared eye width. ~0 when the contour collapses.
    public static func eyeOpenness(_ contour: [CGPoint]) -> Double? {
        guard contour.count >= 4 else { return nil }
        var area: CGFloat = 0
        for i in 0..<contour.count {
            let p = contour[i], q = contour[(i + 1) % contour.count]
            area += p.x * q.y - q.x * p.y
        }
        area = abs(area) / 2
        var width: CGFloat = 0
        for i in 0..<contour.count {
            for j in (i + 1)..<contour.count {
                width = max(width, hypot(contour[i].x - contour[j].x, contour[i].y - contour[j].y))
            }
        }
        guard width > .ulpOfOne else { return nil }
        return Double(area / (width * width))
    }

    public static func centroid(_ points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        let n = CGFloat(points.count)
        return CGPoint(x: points.map(\.x).reduce(0, +) / n, y: points.map(\.y).reduce(0, +) / n)
    }

    /// Rough head pose from 2D landmarks, used when Vision omits it.
    /// Yaw: sideways offset of the nose tip from the eye midpoint (the tip
    /// sits ≈0.55 inter-ocular distances in front of the eye plane). Pitch:
    /// where the tip sits between the eye line and the mouth (≈0.6 when
    /// facing the camera). In-plane roll is removed first. Degrees.
    public static func estimatePose(leftEye: CGPoint, rightEye: CGPoint, noseTip: CGPoint, mouth: CGPoint)
        -> (yaw: Double, pitch: Double)? {
        let (l, r) = leftEye.x <= rightEye.x ? (leftEye, rightEye) : (rightEye, leftEye)
        let iod = hypot(r.x - l.x, r.y - l.y)
        guard iod > .ulpOfOne else { return nil }
        let roll = atan2(r.y - l.y, r.x - l.x)
        let mid = CGPoint(x: (l.x + r.x) / 2, y: (l.y + r.y) / 2)
        func unroll(_ p: CGPoint) -> CGPoint {
            let dx = p.x - mid.x, dy = p.y - mid.y
            return CGPoint(x: dx * cos(-roll) - dy * sin(-roll), y: dx * sin(-roll) + dy * cos(-roll))
        }
        let tip = unroll(noseTip), m = unroll(mouth)
        let sideways = Double(tip.x / (0.55 * iod))
        let yaw = asin(max(-1, min(1, sideways))) * 180 / .pi
        guard abs(m.y) > .ulpOfOne else { return nil }
        let along = Double(tip.y / m.y) // 0 at the eye line, 1 at the mouth
        let pitch = asin(max(-1, min(1, (along - 0.6) / 0.8))) * 180 / .pi
        return (yaw, pitch)
    }

    /// Eye-line-to-mouth distance divided by inter-ocular distance.
    public static func faceShape(leftEye: CGPoint, rightEye: CGPoint, mouth: CGPoint) -> Double? {
        let interocular = hypot(leftEye.x - rightEye.x, leftEye.y - rightEye.y)
        guard interocular > .ulpOfOne else { return nil }
        let mid = CGPoint(x: (leftEye.x + rightEye.x) / 2, y: (leftEye.y + rightEye.y) / 2)
        return Double(hypot(mouth.x - mid.x, mouth.y - mid.y) / interocular)
    }
}
