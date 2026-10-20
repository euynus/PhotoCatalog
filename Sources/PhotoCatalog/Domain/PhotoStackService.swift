// ============================================================
//  PhotoStackService - derive collapsible stacks from duplicate/similar groups
//  (PRD §6.8 ORGZ-005)
// ============================================================
import Foundation

enum PhotoStackService {
    /// Stacks from `groups` first, then from `captureTimeGroups` (see `captureTimeGroups(_:within:)`);
    /// a photo already in a stack isn't taken again. Each stack's id is worked out in chunks
    /// side by side: one by one they took ~20 ms for 30k stacks.
    static func stacks(from groups: [DuplicateGroup], captureTimeGroups: [[String]] = [],
                       chunk: Int = 4_096) -> [PhotoStack] {
        var used = Set<String>(minimumCapacity: groups.reduce(0) { $0 + $1.items.count }
                                   + captureTimeGroups.reduce(0) { $0 + $1.count })
        var members: [(method: String, ids: [String])] = []
        members.reserveCapacity(groups.count + captureTimeGroups.count)
        for group in groups {
            var ids: [String] = []
            ids.reserveCapacity(group.items.count)
            for item in group.items {
                let id = item.id
                if used.insert(id).inserted { ids.append(id) }
            }
            guard ids.count > 1 else { continue }
            members.append((group.method, ids))
        }
        for group in captureTimeGroups {
            let ids = group.filter { used.insert($0).inserted }
            guard ids.count > 1 else { continue }
            members.append(("captureTime", ids))
        }
        func stack(_ member: (method: String, ids: [String])) -> PhotoStack {
            PhotoStack(id: stableId(method: member.method, assetIds: member.ids), method: member.method,
                       assetIds: member.ids)
        }
        let chunk = max(chunk, 1)
        let chunks = members.isEmpty ? 0 : (members.count - 1) / chunk + 1
        guard chunks > 1 else { return members.map(stack) }
        let lock = NSLock()
        var parts = [[PhotoStack]](repeating: [], count: chunks)
        DispatchQueue.concurrentPerform(iterations: chunks) { index in
            let part = members[index * chunk ..< min(members.count, (index + 1) * chunk)].map(stack)
            lock.withLock { parts[index] = part }
        }
        return Array(parts.joined())
    }

    /// Bursts and brackets: photos from one camera each taken within `seconds` of the one before,
    /// as groups of ids in capture order. Photos without a camera (scans, screenshots) and
    /// lone photos stay out.
    static func captureTimeGroups(_ assets: [Asset], within seconds: TimeInterval) -> [[String]] {
        let ranks = cameraRanks(assets.lazy.map(\.camera).filter { !$0.isEmpty })
        var order = assets.indices.compactMap { position -> CaptureKey? in
            let camera = assets[position].camera
            guard let rank = ranks[camera] else { return nil }
            return CaptureKey(camera: rank, position: Int32(position),
                              time: assets[position].date.timeIntervalSinceReferenceDate)
        }
        assets.withUnsafeBufferPointer { photos in order.sort { precedes($0, $1, in: photos) } }
        return groups(inCaptureOrder: order, of: assets, within: seconds)
    }

    /// A photo as capture order places it: by camera (its name's rank among the names), then
    /// capture time, then id. Compact, so that a catalog's photos sort in milliseconds: sorting
    /// the photos themselves by camera, time and id took ~2.5 s at 500k photos.
    struct CaptureKey: Sendable {
        var camera: Int32
        /// The photo's position among the photos ordered.
        var position: Int32
        /// Its capture time as `Date` holds it, whose comparisons and differences are this
        /// number's (a `Date` field, outside Foundation, is copied and compared through calls).
        var time: TimeInterval
    }

    /// Each camera's rank as the names sort. Names Swift holds equal (one name in two Unicode
    /// forms) share a rank, as they compare equal when sorted themselves.
    static func cameraRanks(_ cameras: some Sequence<String>) -> [String: Int32] {
        var ranks: [String: Int32] = [:]
        for camera in cameras { ranks[camera] = 0 }
        for (rank, camera) in ranks.keys.sorted().enumerated() { ranks[camera] = Int32(rank) }
        return ranks
    }

    /// Whether `a` comes before `b` in capture order, `photos` being the photos they're
    /// positions of: by camera, time and id, as tuples of them sort, and then by position, as a
    /// stable sort leaves photos alike in all three — so the order is total.
    static func precedes(_ a: CaptureKey, _ b: CaptureKey, in photos: UnsafeBufferPointer<Asset>) -> Bool {
        if a.camera != b.camera { return a.camera < b.camera }
        if a.time != b.time { return a.time < b.time }
        let (first, second) = (photos[Int(a.position)].id, photos[Int(b.position)].id)
        if first != second { return first < second }
        return a.position < b.position
    }

    /// The groups `captureTimeGroups(_:within:)` makes of photos in capture order (`order`, of
    /// `assets`): a pass over the order, so that any interval reads one sorting of the photos.
    static func groups(inCaptureOrder order: [CaptureKey], of assets: [Asset],
                       within seconds: TimeInterval) -> [[String]] {
        var groups: [[String]] = []
        var start = 0
        func close(at end: Int) {
            if end - start > 1 { groups.append(order[start..<end].map { assets[Int($0.position)].id }) }
            start = end
        }
        for index in order.indices.dropFirst() {
            let (previous, key) = (order[index - 1], order[index])
            if previous.camera == key.camera, key.time - previous.time <= seconds { continue }
            close(at: index)
        }
        close(at: order.count)
        return groups
    }

    static func stack(containing assetId: String, in stacks: [PhotoStack]) -> PhotoStack? {
        stacks.first { $0.assetIds.contains(assetId) }
    }

    /// `assets` with each folded stack showing only the first of its photos among them. The
    /// photos are looked up in chunks side by side: one by one, the list of 500k photos took
    /// ~40 ms to fold.
    static func visibleAssets(_ assets: [Asset], stacks: [PhotoStack],
                              collapsedStackIds: Set<String>, chunk: Int = 32_768) -> [Asset] {
        guard !collapsedStackIds.isEmpty else { return assets }
        // each folded stack's photos by the stack's number (stacks of one id share one)
        var numbers: [String: Int] = [:]
        var stackByAsset: [String: Int] = [:]
        for stack in stacks where collapsedStackIds.contains(stack.id) {
            let number = numbers[stack.id] ?? numbers.count
            numbers[stack.id] = number
            for id in stack.assetIds { stackByAsset[id] = number }
        }
        guard !stackByAsset.isEmpty else { return assets }
        let folded = found(in: assets, chunk: chunk) { asset, position in
            stackByAsset[asset.id].map { (position: position, stack: $0) }
        }
        // all but the first of each stack's, in order
        var seen = [Bool](repeating: false, count: numbers.count)
        var hidden: [Int] = []
        for photo in folded {
            if seen[photo.stack] { hidden.append(photo.position) } else { seen[photo.stack] = true }
        }
        guard !hidden.isEmpty else { return assets }
        var visible: [Asset] = []
        visible.reserveCapacity(assets.count - hidden.count)
        var start = 0
        for position in hidden {
            visible.append(contentsOf: assets[start..<position])
            start = position + 1
        }
        visible.append(contentsOf: assets[start...])
        return visible
    }

    /// What `result` finds in each photo (given with its position), in chunks side by side,
    /// joined in catalog order: the passes over every photo that stacks take.
    static func found<T>(in assets: [Asset], chunk: Int, _ result: (Asset, Int) -> T?) -> [T] {
        let chunk = max(chunk, 1)
        let chunks = assets.isEmpty ? 0 : (assets.count - 1) / chunk + 1
        // the photos through a pointer: threads reading one array retained its buffer by turns
        return assets.withUnsafeBufferPointer { photos in
            func part(_ range: Range<Int>) -> [T] { range.compactMap { result(photos[$0], $0) } }
            guard chunks > 1 else { return part(photos.indices) }
            let lock = NSLock()
            var parts = [[T]](repeating: [], count: chunks)
            DispatchQueue.concurrentPerform(iterations: chunks) { index in
                let found = part(index * chunk ..< min(assets.count, (index + 1) * chunk))
                lock.withLock { parts[index] = found }
            }
            return Array(parts.joined())
        }
    }

    private static func stableId(method: String, assetIds: [String]) -> String {
        "stack-\(method)-" + assetIds.sorted().joined(separator: "-")
    }
}
