import Foundation
import CoreGraphics

public protocol AircraftNoseDetecting: AnyObject {
    func detect(image: CGImage, body: BoxD, isCancelled: () -> Bool,
                progress: ((Double) -> Void)?) throws -> AircraftNoseObservation?
    func close()
}

public struct AircraftFrameObservation: Codable, Sendable {
    public enum Source: String, Codable, Sendable { case missing, detected, tracked }
    public var nose: AircraftNoseObservation? = nil
    public var source: Source = .missing
    public var registrationQuality: Double? = nil
}

/// Per-burst semantic seeds plus actual image tracking. Not yet wired to the product analyzer.
public enum AircraftSequenceAnalyzer {
    /// This analysis owns the supplied detector's session lifetime and closes it on every exit.
    /// Boxes and decoded proxies must use the same pixel coordinates. Retains only the seed
    /// image and adjacent images, and never propagates a nose through a missing observation.
    public static func run(bodies: [BoxD?], clips: [BurstClip] = [], detector: AircraftNoseDetecting,
                           refreshInterval: Int = 15, retryInterval: Int = 5,
                           loadImage: (Int) throws -> CGImage?, isCancelled: () -> Bool = { false },
                           progress: ((Double) -> Void)? = nil) throws -> [AircraftFrameObservation] {
        defer { detector.close() }
        guard refreshInterval > 0, retryInterval > 0 else { throw ModelError.badOutput("飞机重检间隔必须大于零") }
        let count = bodies.count
        var ranges: [Range<Int>] = []
        if clips.isEmpty {
            if count > 0 { ranges = [0..<count] }
        } else {
            var cursor = 0
            for clip in clips {
                guard clip.start == cursor, clip.count > 0, clip.count <= count-cursor else {
                    throw ModelError.badOutput("飞机片段范围必须连续、不重叠并覆盖照片")
                }
                ranges.append(cursor..<(cursor+clip.count)); cursor += clip.count
            }
            guard cursor == count else { throw ModelError.badOutput("飞机片段范围必须覆盖所有照片") }
        }
        var result = [AircraftFrameObservation](repeating: AircraftFrameObservation(), count: count), completed = 0
        func check() throws { if isCancelled() { throw CancellationError() } }
        func report(_ fraction: Double = 0) { progress?(min(1, (Double(completed)+fraction)/Double(max(1,count)))) }
        func valid(_ body: BoxD?) -> Bool {
            guard let b = body else { return false }
            return [b.x,b.y,b.w,b.h,b.score].allSatisfy(\.isFinite) && b.w > 0 && b.h > 0
        }
        func read(_ index: Int) throws -> CGImage? {
            try check()
            let image = try loadImage(index)
            try check()
            return image
        }
        func detect(_ index: Int, _ image: CGImage) throws -> AircraftNoseObservation? {
            try check()
            let nose = try detector.detect(image: image, body: bodies[index]!, isCancelled: isCancelled,
                                             progress: { report($0*0.9) })
            try check()
            if let nose { result[index] = AircraftFrameObservation(nose: nose, source: .detected) }
            return nose
        }
        try check(); report()
        for indices in ranges {
            let candidates = indices.filter { valid(bodies[$0]) }
            guard let seed = candidates.max(by: {
                let a = bodies[$0]!, b = bodies[$1]!
                return a.score*sqrt(a.w*a.h) < b.score*sqrt(b.w*b.h)
            }) else {
                completed += indices.count; report(); continue
            }
            let seedImage = try read(seed)
            let seedNose = try seedImage.flatMap { try detect(seed,$0) }
            completed += 1; report()
            for direction in [1,-1] {
                let tracker = AircraftNoseTracker()
                var previousIndex = seed, previousImage = seedImage, previousNose = seedNose
                var sinceDetection = 0, retryAfter = seedNose == nil ? retryInterval : 0, index = seed+direction
                while indices.contains(index) {
                    try check()
                    var image: CGImage?, nose: AircraftNoseObservation?
                    retryAfter = max(0,retryAfter-1)
                    if valid(bodies[index]) {
                        image = try read(index)
                        if let image {
                            if let previousNose, let previousImage, sinceDetection+1 < refreshInterval,
                               let tracked = tracker.step(previous: previousImage, current: image, nose: previousNose,
                                                          previousBody: bodies[previousIndex]!, currentBody: bodies[index]!) {
                                nose = tracked.nose
                                result[index] = AircraftFrameObservation(nose: tracked.nose, source: .tracked, registrationQuality: tracked.registrationQuality)
                            }
                            if nose == nil && (previousNose != nil || retryAfter == 0) {
                                nose = try detect(index,image)
                                sinceDetection = -1; retryAfter = nose == nil ? retryInterval : 0
                            }
                        }
                    }
                    previousIndex = index; previousImage = image; previousNose = nose
                    sinceDetection += 1; completed += 1; report(); index += direction
                }
            }
        }
        try check(); report()
        return result
    }
}
