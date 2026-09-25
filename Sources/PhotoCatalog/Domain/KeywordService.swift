import Foundation

enum KeywordService {
    static func normalize(_ raw: String) -> [String] {
        normalize(raw.split { isEntrySeparator($0) }.map(String.init))
    }

    static func normalize(_ rawKeywords: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in rawKeywords {
            let components = hierarchyComponents(raw)
            guard !components.isEmpty else { continue }
            for index in components.indices {
                let keyword = components[...index].joined(separator: "/")
                if seen.insert(keyword).inserted {
                    result.append(keyword)
                }
            }
        }
        return result
    }

    /// Whether `keyword` is `root` or sits under it in the hierarchy.
    static func isWithin(_ keyword: String, _ root: String) -> Bool {
        keyword == root || keyword.hasPrefix(root + "/")
    }

    /// A photo's keywords after renaming `old` — and everything under it — to `new`; renaming
    /// onto an existing keyword merges the two. A nil or empty `new` deletes them instead.
    static func replacing(_ old: String, with new: String?, in keywords: [String]) -> [String] {
        let target = new.map { normalize($0).last ?? "" } ?? ""
        var result: [String] = []
        for keyword in keywords {
            guard isWithin(keyword, old) else {
                result.append(keyword)
                continue
            }
            if !target.isEmpty { result.append(target + keyword.dropFirst(old.count)) }
        }
        return normalize(result)
    }

    static func suggestions(for input: String, pool: [String], excluding: [String], limit: Int = 5) -> [String] {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let excluded = Set(excluding)
        var seen = Set<String>()
        var result: [String] = []
        for keyword in pool where !excluded.contains(keyword)
            && keyword.localizedStandardContains(query)
            && seen.insert(keyword).inserted {
            result.append(keyword)
            if result.count >= limit { break }
        }
        return result
    }

    private static func hierarchyComponents(_ raw: String) -> [String] {
        raw.split { isHierarchySeparator($0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func isEntrySeparator(_ character: Character) -> Bool {
        character == "," || character == "，" || character == ";" || character == "；" || character == "\n"
    }

    private static func isHierarchySeparator(_ character: Character) -> Bool {
        character == "/" || character == "／" || character == ">" || character == "＞" || character == "›"
    }
}
