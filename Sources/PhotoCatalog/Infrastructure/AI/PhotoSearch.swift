// ============================================================
//  Natural-language search — a sentence turned into the filter bar and the search box
// ============================================================
import Foundation

/// Asks a language model to read a request like "photos from the beach last summer, four stars up" as the
/// catalog's own filters (rating, flag, color label, file type, camera, lens, capture dates,
/// location) and search words, and checks what comes back against what those filters accept.
enum PhotoSearch {
    struct Interpretation: Equatable, Sendable {
        var filters = Filters()
        /// Words for the search box: keywords, titles, captions, places.
        var text = ""
    }

    /// What the catalog holds, so the model can name the camera or keyword the user means.
    struct Vocabulary: Sendable {
        var cameras: [String] = []
        var lenses: [String] = []
        var keywords: [String] = []
        var types: [String] = []
    }

    private static let chineseExamples = ["猫", "海滩", "日落"]

    static func request(_ query: String, today: Date, vocabulary: Vocabulary, chinese: Bool) -> LLMRequest {
        let lastYear = Calendar.captureWallClock.component(.year, from: today) - 1
        // the examples' search words in the catalog's language, or small models answer in English
        let examples = chinese ? chineseExamples : ["cat", "beach", "sunset"]
        let (cat, beach, sunset) = (examples[0], examples[1], examples[2])
        let system = """
        You turn a request for photos into search filters for a photo catalog. Reply with only a JSON object holding \
        only the fields the request asks for — most requests need one or two, and {} is a fine answer:
        {"text": string, "minRating": 1-5, "flag": "pick" | "reject", "color": "red" | "orange" | "yellow" | "green" | \
        "blue" | "purple", "type": "RAW" or a file type, "camera": string, "lens": string, "dateStart": "YYYY-MM-DD", \
        "dateEnd": "YYYY-MM-DD", "gps": "yes" | "no"}
        - text: one to three words for what the photos show or are about — subjects, places, events — in the catalog's \
        language (\(chinese ? "Simplified Chinese" : "English")); prefer the catalog's own keywords. Never put words for \
        ratings, flags, labels, dates, gear or location in text: they have their own fields.
        - Dates: today is \(today.formatted(.iso8601.year().month().day())); resolve "last summer", "last year", "in March" \
        and the like, in any language, to a start and end date.
        - camera, lens, type: use a value from the catalog's lists when one matches.
        - flag "pick" for picked or kept photos, "reject" for rejected ones; gps "yes" for photos with a location.
        Never fill in a field just because the catalog has values for it. Examples:
        "photos of cats" → {"text": "\(cat)"}
        "beach photos rated three stars or more" → {"text": "\(beach)", "minRating": 3}
        "blue-label rejects" → {"color": "blue", "flag": "reject"}
        "sunsets from last year's summer" → {"text": "\(sunset)", "dateStart": "\(lastYear)-06-01", "dateEnd": "\(lastYear)-08-31"}
        "taken with the 50mm" → {"lens": "RF50mm F1.8 STM"}
        """
        let prompt = """
        Request: \(query)

        The catalog's cameras: \(vocabulary.cameras.prefix(30).joined(separator: "; "))
        Lenses: \(vocabulary.lenses.prefix(30).joined(separator: "; "))
        File types: \(vocabulary.types.joined(separator: ", "))
        Keywords: \(vocabulary.keywords.prefix(150).joined(separator: ", "))
        """
        return LLMRequest(system: system, prompt: prompt, maxTokens: 300)
    }

    /// The filters in a reply, each checked against what the filter bar accepts — and, since
    /// smaller models fill in fields for the sake of it, against `query`: a filter counts only
    /// when the sentence says something about it. Nil when the reply holds no JSON.
    static func parse(_ reply: String, vocabulary: Vocabulary, query: String) -> Interpretation? {
        guard var json = LLMClient.jsonObject(in: reply) else { return nil }
        let asked = query.lowercased()
        // Latin words count whole ("fall", not "waterfall"), even between Chinese characters
        let words = Set((try? NSRegularExpression(pattern: "[a-z0-9]+"))?.matches(in: asked, range: NSRange(asked.startIndex..., in: asked))
            .compactMap { Range($0.range, in: asked).map { String(asked[$0]) } } ?? [])
        func mentions(_ cues: [String]) -> Bool {
            cues.contains { $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } ? words.contains($0) : asked.contains($0) }
        }
        if !mentions(Cue.ratingCues) { json["minRating"] = nil }
        if !mentions(Cue.pickCues + Cue.rejectCues + Cue.flagCues) { json["flag"] = nil }
        if let color = (json["color"] as? String)?.lowercased() {
            // "红叶" is red leaves; a color label is asked for as a label
            let chinese = Cue.colorCues[color] ?? color
            if !mentions([color, chinese]) || !mentions(Cue.labelCues + Cue.labelSuffixCues.map { chinese + $0 }) { json["color"] = nil }
        }
        if !mentions(Cue.typeCues + vocabulary.types.map { $0.lowercased() }) { json["type"] = nil }
        if let camera = json["camera"] as? String {
            let maker = Cue.makerCues.filter { camera.lowercased().contains($0.key) }.map(\.value)
            if !mentions(nameParts(camera) + maker) { json["camera"] = nil }
        }
        if let lens = json["lens"] as? String, !mentions(focalParts(lens)) { json["lens"] = nil }
        if !mentions(Cue.locationCues) { json["gps"] = nil }
        if !mentions(Cue.dateCues) && asked.range(of: #"(19|20)\d\d"#, options: .regularExpression) == nil {
            json["dateStart"] = nil
            json["dateEnd"] = nil
        }
        func text(_ key: String) -> String {
            (json[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        var result = Interpretation()
        result.text = text("text")
        if let rating = (json["minRating"] as? NSNumber)?.intValue ?? Int(text("minRating")) {
            result.filters.minRating = min(5, max(0, rating))
        }
        if ["pick", "reject"].contains(text("flag")) { result.filters.flag = text("flag") }
        if ColorLabel(rawValue: text("color").lowercased()) != nil { result.filters.color = text("color").lowercased() }
        let type = text("type").uppercased()
        if type == "RAW" || vocabulary.types.contains(type) { result.filters.type = type }
        result.filters.camera = text("camera")
        result.filters.lens = text("lens")
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = Calendar.captureWallClock.timeZone
        day.dateFormat = "yyyy-MM-dd"
        let start = day.date(from: text("dateStart")), end = day.date(from: text("dateEnd"))
        if start != nil || end != nil {
            result.filters.date = "custom"
            result.filters.dateStart = start
            result.filters.dateEnd = end
        }
        if ["yes", "no"].contains(text("gps")) { result.filters.gps = text("gps") }
        // They also put filters in the search words ("精选", "红色标签"), which then match nothing. Search words
        // made only of filter words become the flag or label they name, and go once any filter is set.
        let restated = Cue.ratingCues + Cue.pickCues + Cue.rejectCues + Cue.colorCues.keys + Cue.colorCues.values + Cue.labelCues
            + Cue.labelSuffixCues + Cue.typeCues + Cue.locationCues + Cue.dateCues + Cue.fillerCues + vocabulary.types.map { $0.lowercased() }
        let searchWords = result.text.lowercased()
        var rest = searchWords
        for word in restated.sorted(by: { $0.count > $1.count }) { rest = rest.replacingOccurrences(of: word, with: "") }
        let ignored = CharacterSet.decimalDigits.union(.whitespacesAndNewlines).union(.punctuationCharacters)
        if !searchWords.isEmpty && rest.unicodeScalars.allSatisfy(ignored.contains) {
            if result.filters.flag == "any" {
                if Cue.pickCues.contains(where: searchWords.contains) { result.filters.flag = "pick" }
                if Cue.rejectCues.contains(where: searchWords.contains) { result.filters.flag = "reject" }
            }
            if result.filters.color == "any",
               let color = Cue.colorCues.first(where: { searchWords.contains($0.key) || searchWords.contains($0.value) }),
               (Cue.labelCues + Cue.labelSuffixCues.map { color.value + $0 }).contains(where: searchWords.contains) {
                result.filters.color = color.key
            }
            if result.filters != Filters() { result.text = "" }
        }
        return result
    }

    /// Words that show a request is about a filter, in both of the app's languages.
    private enum Cue {
        static let ratingCues = ["星以上", "星及以上", "颗星", "星级", "星的", "评分", "评级", "分以上", "一星", "二星", "两星", "三星", "四星", "五星", "1星", "2星", "3星", "4星", "5星"]
            + ["star", "stars", "starred", "rating", "rated"]
        static let pickCues = ["精选", "留用", "选中", "pick", "picks", "picked", "keeper", "keepers"]
        static let rejectCues = ["拒绝", "被拒", "排除", "reject", "rejects", "rejected"]
        static let flagCues = ["旗标", "flag", "flagged"]
        static let colorCues = ["red": "红", "orange": "橙", "yellow": "黄", "green": "绿", "blue": "蓝", "purple": "紫"]
        static let labelCues = ["标签", "色标", "标记", "标为", "标成", "label", "labels", "labeled", "labelled"]
        static let labelSuffixCues = ["标"]
        static let typeCues = ["raw", "jpg", "jpeg", "heic", "tif", "tiff", "dng", "png", "格式", "文件类型", "format", "file type"]
        static let makerCues = ["canon": "佳能", "nikon": "尼康", "sony": "索尼", "fujifilm": "富士", "leica": "徕卡", "panasonic": "松下", "olympus": "奥林巴斯", "hasselblad": "哈苏", "dji": "大疆", "apple": "苹果", "ricoh": "理光", "sigma": "适马"]
        static let locationCues = ["位置", "地点", "定位", "坐标", "地图", "gps", "location", "geotag", "geotagged", "place"]
        static let millimetreCues = ["毫米"]
        /// Words around a request that say nothing about the photos themselves.
        static let fillerCues = ["的", "色", "照片", "图片", "相片", "拍", "张", "去", "天", "带", "有", "和", "photos", "photo", "pictures", "with", "from", "the", "and"]
        static let dateCues = ["年", "月", "日期", "今天", "昨天", "前天", "天前", "周", "星期", "季", "春", "夏", "秋", "冬", "最近", "以前", "以来", "之后"]
            + ["year", "years", "month", "months", "week", "weeks", "day", "days", "today", "yesterday", "last", "ago", "spring",
               "summer", "autumn", "fall", "winter", "recent", "recently", "since", "before", "after"]
    }

    /// A camera's name as the words someone might say: "Canon", "EOS", "R6m2".
    private static func nameParts(_ name: String) -> [String] {
        name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 2 }
    }

    /// A lens's focal lengths as someone might say them: "24-70", "50mm", "85".
    private static func focalParts(_ name: String) -> [String] {
        let pattern = try? NSRegularExpression(pattern: #"(\d{2,3})(?:-(\d{2,3}))?\s*mm"#)
        let range = NSRange(name.startIndex..., in: name)
        return (pattern?.matches(in: name, range: range) ?? []).flatMap { match -> [String] in
            let first = Range(match.range(at: 1), in: name).map { String(name[$0]) } ?? ""
            if let second = Range(match.range(at: 2), in: name).map({ String(name[$0]) }) { return ["\(first)-\(second)"] }
            return ["\(first)mm", "\(first) mm"] + Cue.millimetreCues.map { first + $0 }
        }
    }
}
