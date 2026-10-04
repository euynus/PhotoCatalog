import Foundation

/// In-memory proposals only. Catalog writes belong to the caller after explicit acceptance.
struct DescriptionReview: Equatable, Sendable {
    struct Options: Equatable, Sendable {
        var keywords = true
        var title = true
        var caption = true
        var replace = false
        var includeMetadata = false

        var isEmpty: Bool { !keywords && !title && !caption }
    }

    enum Outcome: Equatable, Sendable {
        case pending
        case success(PhotoDescriber.Description)
        case failure(String)
    }

    struct Item: Identifiable, Equatable, Sendable {
        let id: String
        let filename: String
        /// An existing local cache file, never a retained request image or base64 payload.
        let previewPath: String?
        let existing: PhotoDescriber.Description
        var outcome: Outcome = .pending

        init(asset: Asset) {
            id = asset.id
            filename = asset.filename
            previewPath = Self.localPath(asset.thumb) ?? Self.localPath(asset.preview)
            existing = PhotoDescriber.Description(title: asset.title, caption: asset.caption, keywords: asset.keywords)
        }

        var proposed: PhotoDescriber.Description? {
            if case .success(let description) = outcome { return description }
            return nil
        }

        var failure: String? {
            if case .failure(let message) = outcome { return message }
            return nil
        }

        /// The changes shown by review; the caller must still apply its policy to live values.
        func changes(options: Options) -> PhotoDescriber.Description? {
            guard let proposed else { return nil }
            var keywords: [String] = []
            var seen = Set(existing.keywords)
            if options.keywords {
                keywords = proposed.keywords.filter { !$0.isEmpty && seen.insert($0).inserted }
            }
            let title = options.title && !proposed.title.isEmpty && proposed.title != existing.title
                && (options.replace || existing.title.isEmpty) ? proposed.title : ""
            let caption = options.caption && !proposed.caption.isEmpty && proposed.caption != existing.caption
                && (options.replace || existing.caption.isEmpty) ? proposed.caption : ""
            guard !keywords.isEmpty || !title.isEmpty || !caption.isEmpty else { return nil }
            return PhotoDescriber.Description(title: title, caption: caption, keywords: keywords)
        }

        private static func localPath(_ source: String) -> String? {
            guard !source.isEmpty else { return nil }
            if source.hasPrefix("/") { return source }
            guard let url = URL(string: source), url.isFileURL,
                  url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
            return url.path
        }
    }

    let options: Options
    private(set) var items: [Item]
    private(set) var selectedIDs: Set<String> = []

    init(targets: [Asset], options: Options = Options()) {
        self.options = options
        var seen = Set<String>()
        items = targets.filter { seen.insert($0.id).inserted }.map(Item.init(asset:))
    }

    var successfulItems: [Item] { items.filter { $0.proposed != nil } }
    var failedItems: [Item] { items.filter { $0.failure != nil } }
    var failedIDs: [String] { failedItems.map(\.id) }
    var pendingCount: Int { items.filter { $0.outcome == .pending }.count }
    var selectableIDs: Set<String> { Set(items.filter { $0.changes(options: options) != nil }.map(\.id)) }

    /// Reading this payload has no side effects; remove accepted rows only after a successful write.
    var selectedDescriptions: [String: PhotoDescriber.Description] {
        var result: [String: PhotoDescriber.Description] = [:]
        for item in items where selectedIDs.contains(item.id) {
            if let changes = item.changes(options: options) { result[item.id] = changes }
        }
        return result
    }

    mutating func setSelected(_ selected: Bool, for id: String) {
        if selected, items.contains(where: { $0.id == id && $0.changes(options: options) != nil }) {
            selectedIDs.insert(id)
        } else {
            selectedIDs.remove(id)
        }
    }

    mutating func selectAll(_ selected: Bool) {
        selectedIDs = selected ? selectableIDs : []
    }

    /// Merge only returned outcomes. Unattempted failures survive cancellation or partial retries.
    mutating func record(descriptions: [String: PhotoDescriber.Description] = [:], failures: [String: String] = [:]) {
        for index in items.indices {
            let id = items[index].id
            if let description = descriptions[id] {
                items[index].outcome = .success(description)
            } else if let failure = failures[id] {
                items[index].outcome = .failure(failure)
            } else {
                continue
            }
            // A replacement result always needs a fresh selection, including after a retry.
            selectedIDs.remove(id)
        }
    }

    mutating func failPending(_ message: String) {
        let failures = Dictionary(uniqueKeysWithValues: items.filter { $0.outcome == .pending }.map { ($0.id, message) })
        record(failures: failures)
    }

    /// A newer local edit must be visible before the user accepts a replacement proposal.
    @discardableResult
    mutating func refreshExisting(from assets: [Asset]) -> Bool {
        let live = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var refreshed = false
        for index in items.indices {
            guard let asset = live[items[index].id] else { continue }
            var updated = Item(asset: asset)
            guard updated.existing != items[index].existing else { continue }
            updated.outcome = items[index].outcome
            items[index] = updated
            selectedIDs.remove(updated.id)
            refreshed = true
        }
        return refreshed
    }

    mutating func removeApplied(_ ids: Set<String>) {
        let applied = ids.intersection(Set(selectedDescriptions.keys))
        items.removeAll { applied.contains($0.id) }
        selectedIDs.subtract(applied)
    }
}
