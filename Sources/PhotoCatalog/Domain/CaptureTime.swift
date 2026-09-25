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

enum CaptureDateSource {
    /// Where a capture time came from, in the user's language. The catalog stores the Chinese
    /// names (and EXIF tag names, shown as they are), so only the display is translated.
    static func label(_ stored: String) -> String {
        switch stored {
        case "文件创建时间": return L("文件创建时间")
        case "文件修改时间": return L("文件修改时间")
        case "手动调整": return L("手动调整")
        case "手动设置": return L("手动设置")
        case "sidecar": return L("XMP 附属文件")
        default: return stored
        }
    }
}
