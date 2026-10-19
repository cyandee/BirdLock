import Foundation
import CoreGraphics

/// Experimental aircraft observations. No bird-pose keypoints or body-centre nose fallback.
/// The product analyzer does not select aircraft mode yet.
public struct AircraftNoseObservation: Codable, Sendable {
    public var x: Double, y: Double, w: Double, h: Double
    /// Raw detector score, not a calibrated probability. Zero views means image tracking.
    public var score: Double
    public var views: Int
    public var center: V2 { V2(x + w / 2, y + h / 2) }
    public init(x: Double, y: Double, w: Double, h: Double, score: Double, views: Int) {
        self.x = x; self.y = y; self.w = w; self.h = h; self.score = score; self.views = views
    }
}

public struct AircraftPartCandidate: Sendable {
    /// Rotation of the independent detector query. x/y are candidate centre coordinates.
    public var rotation: Int
    public var score: Double, x: Double, y: Double, w: Double, h: Double
    public init(rotation: Int, score: Double, x: Double, y: Double, w: Double, h: Double) {
        self.rotation = rotation; self.score = score; self.x = x; self.y = y; self.w = w; self.h = h
    }
}

public enum AircraftPartConsensus {
    /// Each direction votes at most once. Missing agreement remains a missing observation.
    public static func choose(_ candidates: [AircraftPartCandidate], body: BoxD, minViews: Int = 2) -> AircraftNoseObservation? {
        let span = max(body.w, body.h)
        guard span.isFinite, span > 0 else { return nil }
        let valid = candidates.filter { c in
            [c.x, c.y, c.w, c.h, c.score].allSatisfy(\.isFinite) && c.w > 0 && c.h > 0 && c.score >= 0.25
        }
        var best: [AircraftPartCandidate] = [], bestWeight = 0.0
        for centre in valid {
            var views: [Int: AircraftPartCandidate] = [:]
            for c in valid where hypot(c.x - centre.x, c.y - centre.y) <= span * 0.12 {
                if c.score > (views[c.rotation]?.score ?? -.infinity) { views[c.rotation] = c }
            }
            // Stable iteration order keeps weighted rounding deterministic across platforms/runs.
            let group = views.keys.sorted().compactMap { views[$0] }
            let weight = group.reduce(0.0) { $0 + $1.score }
            if group.count > best.count || (group.count == best.count && weight > bestWeight) {
                best = group; bestWeight = weight
            }
        }
        guard best.count >= max(2, minViews), bestWeight > 0 else { return nil }
        func mean(_ value: (AircraftPartCandidate) -> Double) -> Double {
            best.reduce(0.0) { $0 + value($1) * $1.score } / bestWeight
        }
        let x = mean { $0.x }, y = mean { $0.y }, w = mean { $0.w }, h = mean { $0.h }
        return AircraftNoseObservation(x: x - w / 2, y: y - h / 2, w: w, h: h,
                                       score: bestWeight / Double(best.count), views: best.count)
    }
}

/// Real image registration around an independently detected nose. Single analysis worker only.
public final class AircraftNoseTracker {
    private let correlator = PhaseCorrelator(size: 128)
    public init() { correlator.setGaussianWindow(sigma: 20) }

    public struct Step {
        public var nose: AircraftNoseObservation
        public var registrationQuality: Double
    }

    public func step(previous: CGImage, current: CGImage, nose: AircraftNoseObservation,
                     previousBody: BoxD, currentBody: BoxD) -> Step? {
        let fields = [nose.x, nose.y, nose.w, nose.h, previousBody.x, previousBody.y, previousBody.w,
                      previousBody.h, currentBody.x, currentBody.y, currentBody.w, currentBody.h]
        guard fields.allSatisfy(\.isFinite),
              [nose.w, nose.h, previousBody.w, previousBody.h, currentBody.w, currentBody.h].allSatisfy({ $0 > 0 }) else { return nil }
        let rx = clamp(currentBody.w / previousBody.w, 0.5, 2), ry = clamp(currentBody.h / previousBody.h, 0.5, 2)
        let relative = nose.center - previousBody.center
        let prediction = currentBody.center + V2(relative.x * rx, relative.y * ry)
        let factor = Int(clamp((max(nose.w, nose.h) * 3 / 128).rounded(), 1, 8)), side = 128 * factor
        guard nose.center.x >= 0, nose.center.x < Double(previous.width), nose.center.y >= 0, nose.center.y < Double(previous.height) else { return nil }
        let originA = V2((nose.center.x - Double(side)/2).rounded(), (nose.center.y - Double(side)/2).rounded())
        guard let a = GrayPatch.extractExact(from: previous, x0: Int(originA.x), y0: Int(originA.y), n: 128, factor: factor) else { return nil }
        func variance(_ p: GrayPatch) -> Double {
            let mean = p.data.reduce(0.0) { $0 + Double($1) } / Double(p.data.count)
            return p.data.reduce(0.0) { $0 + pow(Double($1)-mean, 2) } / Double(p.data.count)
        }
        guard variance(a) >= 1e-6 else { return nil }
        var hints = [nose.center]
        if prediction.x.isFinite, prediction.y.isFinite, (prediction-nose.center).length > 1 { hints.append(prediction) }
        var matches: [Step] = []
        for hint in hints {
            guard hint.x >= -Double(side), hint.x <= Double(current.width+side),
                  hint.y >= -Double(side), hint.y <= Double(current.height+side) else { continue }
            let originB = V2((hint.x-Double(side)/2).rounded(),(hint.y-Double(side)/2).rounded())
            guard let b = GrayPatch.extractExact(from: current, x0: Int(originB.x), y0: Int(originB.y), n: 128, factor: factor),
                  variance(b) >= 1e-6, let r = correlator.correlate(a, b), r.quality.isFinite, r.quality >= 25,
                  r.shift.x.isFinite, r.shift.y.isFinite, r.shift.length <= 128 * 0.3 else { continue }
            let point = nose.center + (originB-originA) + r.shift*Double(factor)
            let pad = max(currentBody.w,currentBody.h)*0.22
            guard point.x >= 0, point.x < Double(current.width), point.y >= 0, point.y < Double(current.height),
                  point.x >= currentBody.x-pad, point.x <= currentBody.x+currentBody.w+pad,
                  point.y >= currentBody.y-pad, point.y <= currentBody.y+currentBody.h+pad else { continue }
            // A translation match does not establish part scale. Preserve size until a model refresh.
            let tracked = AircraftNoseObservation(x: point.x-nose.w/2,y: point.y-nose.h/2,w: nose.w,h: nose.h,score: nose.score,views: 0)
            matches.append(Step(nose: tracked,registrationQuality: r.quality))
        }
        matches.sort { $0.registrationQuality > $1.registrationQuality }
        guard let best = matches.first else { return nil }
        if matches.count > 1, (best.nose.center-matches[1].nose.center).length > max(nose.w,nose.h)*0.5,
           best.registrationQuality < matches[1].registrationQuality*1.35 { return nil }
        return best
    }
}
