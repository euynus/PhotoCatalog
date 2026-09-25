// ============================================================
//  PhotoList — the visible photos, cheap for SwiftUI to compare
// ============================================================

/// The current photo list for SwiftUI collections. SwiftUI compares a view's stored values on
/// every update, and `Asset ==` compares ids, so comparing two 500k-photo arrays walked every
/// element — twice per update, ~100 ms per rating — only to find the same ids. `identity`
/// changes whenever the list is rebuilt, so equal identities mean the same photos in the same
/// order; an edit patched into place keeps it, just as `Asset ==` ignores edits.
struct PhotoList: RandomAccessCollection, Equatable {
    let assets: [Asset]
    let identity: Int

    var startIndex: Int { assets.startIndex }
    var endIndex: Int { assets.endIndex }
    subscript(position: Int) -> Asset { assets[position] }

    static func == (lhs: PhotoList, rhs: PhotoList) -> Bool { lhs.identity == rhs.identity }
}
