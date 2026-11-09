// ============================================================
//  Photo description — the title, caption and keywords proposed for a photo
// ============================================================
import Foundation

/// A photo's title, caption and keywords, as a model that reads images proposes them
/// (`PhotoDescriber`) for the user to review.
struct PhotoDescription: Equatable, Sendable {
    var title: String
    var caption: String
    var keywords: [String]
}
