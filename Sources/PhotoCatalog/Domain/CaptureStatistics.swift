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

    init(assets: [Asset]) {
        let live = assets.filter { !$0.deleted }
        totalCount = live.count
        let dates = live.map(\.date).filter { $0.timeIntervalSince1970.isFinite }
        dayCount = Set(dates.map { Calendar.captureWallClock.startOfDay(for: $0) }).count
        firstDate = dates.min()
        lastDate = dates.max()
        completeCount = live.filter { asset in CaptureParameter.allCases.allSatisfy { $0.value(in: asset) != nil } }.count
        fileDateCount = live.filter { $0.captureDateSource.hasPrefix("文件") }.count
        distributions = CaptureParameter.allCases.map { parameter in
            var counts: [String: Int] = [:]
            var missing = 0
            for asset in live {
                if let value = parameter.value(in: asset) {
                    counts[value, default: 0] += 1
                } else {
                    missing += 1
                }
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
    }
}
