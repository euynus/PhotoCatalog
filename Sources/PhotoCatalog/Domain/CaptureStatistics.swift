import Foundation

enum CaptureParameter: String, CaseIterable, Identifiable, Sendable {
    case camera, lens, focal, aperture, shutter, iso

    var id: String { rawValue }
    var title: String {
        switch self {
        case .camera: return L("相机")
        case .lens: return L("镜头")
        case .focal: return L("焦距")
        case .aperture: return L("光圈")
        case .shutter: return L("快门")
        case .iso: return "ISO"
        }
    }

    func value(in asset: Asset) -> String? {
        switch self {
        case .camera, .lens:
            let text = (self == .camera ? asset.camera : asset.lens).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        case .focal: return asset.focal > 0 ? String(asset.focal) : nil
        case .aperture: return asset.aperture.isFinite && asset.aperture > 0 ? String(asset.aperture) : nil
        case .shutter: return Self.shutterSeconds(asset.shutter).map { String($0) }
        case .iso: return asset.iso > 0 ? String(asset.iso) : nil
        }
    }

    func label(for value: String) -> String {
        guard let number = Double(value), self != .camera, self != .lens else { return value }
        let formatted = number.formatted(.number.precision(.fractionLength(0...4)))
        switch self {
        case .focal: return "\(formatted) mm"
        case .aperture: return "ƒ/\(formatted)"
        case .shutter:
            let reciprocal = 1 / number
            if number < 1, reciprocal.isFinite, abs(reciprocal - reciprocal.rounded()) < 0.000001 {
                return "1/\(reciprocal.formatted(.number.grouping(.never).precision(.fractionLength(0)))) s"
            }
            return "\(formatted) s"
        case .iso: return "ISO \(value)"
        case .camera, .lens: return value
        }
    }

    static func shutterSeconds(_ value: String) -> Double? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = text.hasSuffix("s") ? String(text.dropLast()).trimmingCharacters(in: .whitespaces) : text
        let parts = number.split(separator: "/", omittingEmptySubsequences: false)
        let result: Double?
        if parts.count == 2, let numerator = Double(parts[0]), let denominator = Double(parts[1]),
           numerator > 0, denominator > 0 {
            result = numerator / denominator
        } else {
            result = Double(number)
        }
        guard let result, result.isFinite, result > 0 else { return nil }
        return result
    }
}

struct CaptureParameterCount: Identifiable, Sendable {
    let value: String
    let count: Int
    var id: String { value }
}

struct CaptureDistribution: Identifiable, Sendable {
    let parameter: CaptureParameter
    let values: [CaptureParameterCount]
    let missingCount: Int
    var id: CaptureParameter { parameter }
    var knownCount: Int { values.reduce(0) { $0 + $1.count } }
}

struct CaptureStatistics: Sendable {
    let totalCount: Int
    let dayCount: Int
    let completeCount: Int
    let fileDateCount: Int
    let firstDate: Date?
    let lastDate: Date?
    let distributions: [CaptureDistribution]

    /// Capture days from 1 AD to 9999 (proleptic Gregorian, by days since 1970). Capture times are
    /// UTC wall clock, so in these years a time's day is whole multiples of 86,400 seconds, as the
    /// calendar's start of day is. Outside them the calendar clamps times to its own limits, so
    /// those days are still asked of it.
    private static let wholeDays = -719_162.0 ..< 2_932_897.0

    /// Counted by each photo's raw values (a number, a camera's name as stored), each distinct one
    /// turned into the text shown once at the end: making six strings per photo, and a calendar
    /// call for its day, was most of the time this took.
    init(assets: [Asset]) throws {
        try Task.checkCancellation()
        let blank = CharacterSet.whitespacesAndNewlines
        var cameras = Tally<String>(), lenses = Tally<String>()
        var focals = Tally<Int>(), apertures = Tally<Double>(), shutters = Tally<Double>(), isos = Tally<Int>()
        var shutterSeconds: [String: Double?] = [:]
        var days = Set<Int>(), farDays = Set<Date>()
        var total = 0, complete = 0, fileDates = 0
        var first: Date?, last: Date?
        for (index, asset) in assets.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard !asset.deleted else { continue }
            total += 1
            let seconds = asset.date.timeIntervalSince1970
            if seconds.isFinite {
                let day = (seconds / 86_400).rounded(.down)
                if Self.wholeDays.contains(day) {
                    days.insert(Int(day))
                } else {
                    farDays.insert(Calendar.captureWallClock.startOfDay(for: asset.date))
                }
                first = first.map { min($0, asset.date) } ?? asset.date
                last = last.map { max($0, asset.date) } ?? asset.date
            }
            if asset.captureDateSource.hasPrefix("文件") { fileDates += 1 }
            // missing as value(in:) has it: blank text, a number that isn't positive, a shutter that doesn't parse
            let camera = asset.camera, lens = asset.lens, shutter = asset.shutter
            let hasCamera = cameras.add(camera.unicodeScalars.allSatisfy(blank.contains) ? nil : camera)
            let hasLens = lenses.add(lens.unicodeScalars.allSatisfy(blank.contains) ? nil : lens)
            let hasFocal = focals.add(asset.focal > 0 ? asset.focal : nil)
            let hasAperture = apertures.add(asset.aperture.isFinite && asset.aperture > 0 ? asset.aperture : nil)
            let exposure: Double?
            if let known = shutterSeconds[shutter] {
                exposure = known
            } else {
                exposure = CaptureParameter.shutterSeconds(shutter)
                shutterSeconds[shutter] = exposure
            }
            let hasShutter = shutters.add(exposure)
            let hasISO = isos.add(asset.iso > 0 ? asset.iso : nil)
            if hasCamera && hasLens && hasFocal && hasAperture && hasShutter && hasISO { complete += 1 }
        }
        try Task.checkCancellation()
        totalCount = total
        dayCount = days.count + farDays.count
        completeCount = complete
        fileDateCount = fileDates
        firstDate = first
        lastDate = last
        distributions = CaptureParameter.allCases.map { parameter in
            // the text value(in:) gives, raw values that show as one (" Canon", "Canon") summed
            let counts: [String: Int], missing: Int
            switch parameter {
            case .camera: (counts, missing) = (cameras.values { $0.trimmingCharacters(in: blank) }, cameras.missing)
            case .lens: (counts, missing) = (lenses.values { $0.trimmingCharacters(in: blank) }, lenses.missing)
            case .focal: (counts, missing) = (focals.values { String($0) }, focals.missing)
            case .aperture: (counts, missing) = (apertures.values { String($0) }, apertures.missing)
            case .shutter: (counts, missing) = (shutters.values { String($0) }, shutters.missing)
            case .iso: (counts, missing) = (isos.values { String($0) }, isos.missing)
            }
            let values = counts.map { CaptureParameterCount(value: $0.key, count: $0.value) }.sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                if parameter != .camera, parameter != .lens, let left = Double($0.value), let right = Double($1.value) {
                    return left < right
                }
                return $0.value.localizedStandardCompare($1.value) == .orderedAscending
            }
            return CaptureDistribution(parameter: parameter, values: values, missingCount: missing)
        }
        try Task.checkCancellation()
    }
}

/// One capture parameter's photos by raw value, and how many have none.
private struct Tally<Key: Hashable> {
    private var counts: [Key: Int] = [:]
    private(set) var missing = 0

    /// Counts a photo's value, or a photo without one when it is nil; whether it had one.
    mutating func add(_ key: Key?) -> Bool {
        guard let key else {
            missing += 1
            return false
        }
        counts[key, default: 0] += 1
        return true
    }

    /// The counts by the text each value is shown as, summed where values show as the same text.
    func values(_ text: (Key) -> String) -> [String: Int] {
        var values: [String: Int] = [:]
        for (key, count) in counts { values[text(key), default: 0] += count }
        return values
    }
}
