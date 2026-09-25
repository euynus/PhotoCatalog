// ============================================================
//  Faces — detected faces, grouped into people
// ============================================================
import Foundation
import CoreGraphics
import Accelerate

/// One face found in a photo.
struct FaceRecord: Identifiable, Equatable, Sendable {
    let id: String
    let assetId: String
    /// Normalized, top-left origin, in the upright photo.
    let box: CGRect
    /// Vision's capture quality, 0…1: sharp, frontal, well-lit faces score high.
    let quality: Float
    /// Vision feature print of the face crop; nearby prints are likely the same person.
    let vector: [Float]
    /// The person's name, once named.
    var person: String?
    /// Named by the user, as opposed to matched automatically.
    var confirmed = false
}

/// Unnamed faces that very likely show one person.
struct FaceCluster: Identifiable, Equatable, Sendable {
    /// The seed (best) face's id, so a group keeps its identity while faces join it.
    let id: String
    let faceIds: [String]
}

enum FaceClustering {
    /// Faces closer than this to a group's centre join it. Tuned on a 2,600-face library:
    /// stricter splits one person by pose and light, looser mixes look-alike people. Vision's
    /// feature print describes appearance, not identity, so groups are suggestions to review.
    static let clusterThreshold: Float = 0.52
    /// A face also has to stay this close to the group's first (clearest) face, which stops
    /// a large group's centre from drifting onto someone else.
    static let seedLimit: Float = 0.65
    /// Blurry, tiny or turned-away faces print unreliably and bridge different people; they
    /// are left out of grouping and matching.
    static let minimumQuality: Float = 0.3
    /// An unnamed face this close to a face the user named is suggested as that person.
    static let matchThreshold: Float = 0.45
    /// Naming a person tags their photos with this keyword, as Lightroom does.
    static let keywordRoot = "人物"

    static func keyword(for person: String) -> String { "\(keywordRoot)/\(person)" }

    /// The person a keyword names, if it is a person keyword.
    static func person(fromKeyword keyword: String) -> String? {
        let prefix = keywordRoot + "/"
        guard keyword.hasPrefix(prefix) else { return nil }
        let name = String(keyword.dropFirst(prefix.count))
        return name.isEmpty || name.contains("/") ? nil : name
    }

    /// A name safe to use as a keyword level.
    static func cleanName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var squared: Float = 0
        vDSP_distancesq(a, 1, b, 1, &squared, vDSP_Length(a.count))
        return squared.squareRoot()
    }

    /// Groups faces around running centres, best faces first so each group is seeded by a
    /// clear face. Largest groups first.
    static func clusters(_ faces: [FaceRecord]) -> [FaceCluster] {
        let order = faces.filter { $0.quality >= minimumQuality && !$0.vector.isEmpty }
            .sorted { ($0.quality, $1.id) > ($1.quality, $0.id) }
        var members: [[String]] = []
        var centres: [[Float]] = []
        var seeds: [[Float]] = []
        for face in order {
            var best = (distance: Float.infinity, index: -1)
            for (index, centre) in centres.enumerated() {
                let d = distance(face.vector, centre)
                if d < best.distance, distance(face.vector, seeds[index]) < seedLimit { best = (d, index) }
            }
            if best.distance < clusterThreshold {
                members[best.index].append(face.id)
                // running mean: centre += (face - centre) / n
                let n = Float(members[best.index].count)
                var step = [Float](repeating: 0, count: face.vector.count)
                vDSP_vsub(centres[best.index], 1, face.vector, 1, &step, 1, vDSP_Length(step.count))
                var scale = 1 / n
                vDSP_vsma(step, 1, &scale, centres[best.index], 1, &centres[best.index], 1, vDSP_Length(step.count))
            } else {
                members.append([face.id])
                centres.append(face.vector)
                seeds.append(face.vector)
            }
        }
        return members.map { FaceCluster(id: $0[0], faceIds: $0) }
            .sorted { ($0.faceIds.count, $1.id) > ($1.faceIds.count, $0.id) }
    }

    /// Names for unnamed faces that sit close to a face the user named. Nearest neighbour, not
    /// a person average, because one person spans several poses.
    static func matches(for unnamed: [FaceRecord], named: [FaceRecord]) -> [String: String] {
        let references = named.filter { $0.confirmed && $0.person != nil && !$0.vector.isEmpty }
        guard !references.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for face in unnamed where face.person == nil && !face.vector.isEmpty && face.quality >= minimumQuality {
            var best = (distance: Float.infinity, person: "")
            for reference in references {
                let d = distance(face.vector, reference.vector)
                if d < best.distance, let person = reference.person { best = (d, person) }
            }
            if best.distance < matchThreshold { result[face.id] = best.person }
        }
        return result
    }
}
