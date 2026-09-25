// ============================================================
//  GPX tracks — place photos along a recorded route by capture time
// ============================================================
import Foundation

struct GPXPoint: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let elevation: Double?
    /// A real (UTC) instant, as GPS receivers record.
    let time: Date
}

struct GPXTrack: Equatable, Sendable {
    /// Fixes in time order.
    let points: [GPXPoint]

    init(points: [GPXPoint]) { self.points = points.sorted { $0.time < $1.time } }

    var start: Date? { points.first?.time }
    var end: Date? { points.last?.time }

    /// Where the track was at `date`: interpolated between the fixes around it when they are
    /// at most `maxGap` apart, otherwise the nearest fix if it is within `tolerance`.
    func location(at date: Date, maxGap: TimeInterval = 600, tolerance: TimeInterval = 120) -> GPXPoint? {
        guard !points.isEmpty else { return nil }
        // first fix at or after the date
        var low = 0, high = points.count
        while low < high {
            let mid = (low + high) / 2
            if points[mid].time < date { low = mid + 1 } else { high = mid }
        }
        let after = low < points.count ? points[low] : nil
        let before = low > 0 ? points[low - 1] : nil
        if let before, let after {
            let span = after.time.timeIntervalSince(before.time)
            if span <= maxGap {
                let t = span > 0 ? date.timeIntervalSince(before.time) / span : 0
                let elevation = zip(before.elevation, after.elevation).map { $0 + ($1 - $0) * t }
                return GPXPoint(latitude: before.latitude + (after.latitude - before.latitude) * t,
                                longitude: before.longitude + (after.longitude - before.longitude) * t,
                                elevation: elevation, time: date)
            }
        }
        let nearest = [before, after].compactMap { $0 }.min {
            abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date))
        }
        guard let nearest, abs(nearest.time.timeIntervalSince(date)) <= tolerance else { return nil }
        return nearest
    }

    /// The UTC instant of a capture time, which the catalog keeps as the camera's wall clock.
    static func instant(ofCapture wallClock: Date, cameraUTCOffset seconds: Int) -> Date {
        wallClock.addingTimeInterval(-TimeInterval(seconds))
    }
}

private func zip(_ a: Double?, _ b: Double?) -> (Double, Double)? {
    guard let a, let b else { return nil }
    return (a, b)
}
