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
