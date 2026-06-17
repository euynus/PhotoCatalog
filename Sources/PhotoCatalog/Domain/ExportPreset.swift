// ============================================================
//  ExportPreset — a named, reusable bundle of export options (PRD §4.2)
// ============================================================
import Foundation

struct ExportPreset: Codable, Identifiable, Equatable {
    var name: String
    var directoryStructure: String
    var writesXMP: Bool
    var id: String { name }
}
