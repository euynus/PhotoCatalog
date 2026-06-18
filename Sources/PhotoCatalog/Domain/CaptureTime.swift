// ============================================================
//  CaptureTime — capture dates are treated as fixed wall-clock,
//  anchored to UTC, so they parse and display identically
//  regardless of the machine's timezone (no travel/DST drift).
//  Every site that maps a capture Date to/from calendar
//  components must use these helpers; importedAt / file
//  timestamps stay in the local calendar.
// ============================================================
import Foundation

extension Calendar {
    /// Gregorian calendar pinned to UTC, for decomposing/comparing capture dates by
    /// day/month/year. Use this (not `.current`) anywhere a capture date is bucketed.
    static let captureWallClock: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
}

extension TimeZone {
    /// The fixed timezone capture wall-clock times are anchored to.
    static let captureWallClock = TimeZone(identifier: "UTC")!
}
