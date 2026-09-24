import Foundation

enum CaptureParameter: String, CaseIterable, Identifiable, Sendable {
    case camera, lens, focal, aperture, shutter, iso

    var id: String { rawValue }
    var title: String {
        switch self {
        case .camera: return "相机"
        case .lens: return "镜头"
        case .focal: return "焦距"
        case .aperture: return "光圈"
        case .shutter: return "快门"
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

    init(assets: [Asset]) throws {
        try Task.checkCancellation()
        let parameters = CaptureParameter.allCases
        var counts = Array(repeating: [String: Int](), count: parameters.count)
        var missing = Array(repeating: 0, count: parameters.count)
        var days = Set<Date>()
        var total = 0, complete = 0, fileDates = 0
        var first: Date?, last: Date?
        for (index, asset) in assets.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard !asset.deleted else { continue }
            total += 1
            if asset.date.timeIntervalSince1970.isFinite {
                days.insert(Calendar.captureWallClock.startOfDay(for: asset.date))
                first = first.map { min($0, asset.date) } ?? asset.date
                last = last.map { max($0, asset.date) } ?? asset.date
            }
            if asset.captureDateSource.hasPrefix("文件") { fileDates += 1 }
            var isComplete = true
            for (index, parameter) in parameters.enumerated() {
                if let value = parameter.value(in: asset) {
                    counts[index][value, default: 0] += 1
                } else {
                    missing[index] += 1
                    isComplete = false
                }
            }
            if isComplete { complete += 1 }
        }
        try Task.checkCancellation()
        totalCount = total
        dayCount = days.count
        completeCount = complete
        fileDateCount = fileDates
        firstDate = first
        lastDate = last
        distributions = parameters.enumerated().map { index, parameter in
            let values = counts[index].map { CaptureParameterCount(value: $0.key, count: $0.value) }.sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                if parameter != .camera, parameter != .lens, let left = Double($0.value), let right = Double($1.value) {
                    return left < right
                }
                return $0.value.localizedStandardCompare($1.value) == .orderedAscending
            }
            return CaptureDistribution(parameter: parameter, values: values, missingCount: missing[index])
        }
        try Task.checkCancellation()
    }
}
