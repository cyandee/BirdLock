import Foundation

/// Nose observations to the shared composition track; called independently for each burst.
/// Legacy `eye` coordinates are a generic anchor here. No aircraft eye was detected or drawn.
enum AircraftTrackBuilder {
    static func build(_ analysis: SequenceAnalysis) -> Track {
        let n = analysis.count
        var points = [V2?](repeating: nil, count: n)
        var lengths = [Double](repeating: .nan, count: n), angles = lengths
        var confidence = [Double](repeating: 0, count: n)
        func valid(_ p: V2, _ index: Int) -> Bool {
            p.x.isFinite && p.y.isFinite && p.x >= 0 && p.y >= 0
                && p.x < Double(analysis.frames[index].pixelWidth) && p.y < Double(analysis.frames[index].pixelHeight)
        }
        for i in 0..<n {
            let per = analysis.perFrame[i]
            if let raw = per.aircraft, raw.source != .missing, let nose = raw.nose,
               [nose.x,nose.y,nose.w,nose.h,nose.score].allSatisfy(\.isFinite), nose.w > 0, nose.h > 0,
               valid(nose.center,i) {
                points[i] = nose.center; lengths[i] = max(nose.w,nose.h)
                confidence[i] = raw.source == .detected ? 0.6 : 0.5
            }
            if let manual = analysis.manualEye[i], valid(manual,i) { points[i] = manual; confidence[i] = 1 }
            if let point = points[i], let body = per.targetBox {
                let direction = point-body.center
                if direction.x.isFinite, direction.y.isFinite, direction.length > 1e-6 { angles[i] = atan2(direction.y,direction.x) }
            }
        }
        let hl: [Double]
        if lengths.contains(where: \.isFinite) {
            let logHL = Signal.fillGaps(Signal.gaussian(Signal.median(lengths.map(log),radius: 4),sigma: 3))
            hl = logHL.map(exp)
        } else { hl = [Double](repeating: 100,count: n) }
        let angle = angles.contains(where: \.isFinite)
            ? Signal.fillGaps(Signal.gaussian(Signal.median(Signal.unwrapAngles(angles),radius: 3),sigma: 2))
            : [Double](repeating: 0,count: n)
        let measurements = (0..<n).map { i in TrajectorySolver.Measurement(value: points[i],sigma: confidence[i] == 1 ? 0.5 : hl[i]*0.05+0.7) }
        // Image tracking already measured these positions; body motion and bird registration links
        // cannot become extra head observations or make a missing nose appear valid.
        let solution = TrajectorySolver.solve(measurements: measurements,
            links: [TrajectorySolver.Link](repeating: .init(delta: nil,sigma: 1),count: n))
        let frames = (0..<n).map { i in TrackFrame(eye: solution.positions[i],headCenter: solution.positions[i],headLength: hl[i],
            angle: angle[i],measuredEye: nil,eyeVisible: false,hasData: points[i] != nil,confidence: confidence[i]) }
        return Track(frames: frames,template: nil,reflectDominant: false,
                     facingRight: (Stats.median(angle.map(cos)) ?? 1) >= 0,medianHeadLength: Stats.median(hl) ?? 100)
    }
}
