import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Select Object and Select Landscape: the masks persist and are told apart; the landscape
/// categories name labels the model has; a landscape mask covers its labels' part of the photo
/// and only it changes; the bundled object model picks out what a click or a box points at.
enum AIMaskCheck {
    static func run() {
        guard [AIModels.Name.segmentation, .objectEncoder, .objectPrompt, .objectDecoder].allSatisfy(AIModels.isAvailable) else {
            return assertionFailure("the mask models are in Resources/Models (script/models/convert.py)")
        }
        checkSettings()
        checkLandscape()
        checkObjects()
        print("--- AI mask assertions passed ---")
    }

    private static func checkSettings() {
        var object = LocalAdjustment(kind: .object)
        object.prompt = ObjectPrompt(box: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
            .adding(CGPoint(x: 0.25, y: 0.3), include: true).adding(CGPoint(x: 0.2, y: 0.5), include: false)
        object.exposure = 0.5
        var landscape = LocalAdjustment(kind: .landscape)
        landscape.landscape = .mountains
        landscape.exposure = -0.3
        var settings = DevelopSettings()
        settings.masks = [object, landscape]
        let stored = try! JSONDecoder().decode(DevelopSettings.self, from: JSONEncoder().encode(settings))
        assert(stored == settings && stored.masks[0].prompt.points.count == 2 && stored.masks[0].prompt.points[1].include == false
               && stored.masks[1].landscape == .mountains, "object and landscape masks persist")

        var older = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(LocalAdjustment(kind: .radial))) as! [String: Any]
        older["prompt"] = nil
        older["landscape"] = nil
        let fromOlder = try! JSONDecoder().decode(LocalAdjustment.self, from: JSONSerialization.data(withJSONObject: older))
        assert(fromOlder.prompt.isEmpty && fromOlder.landscape == .water, "masks saved before them still load")

        var moved = object
        moved.prompt = moved.prompt.adding(CGPoint(x: 0.3, y: 0.3), include: true)
        var water = landscape
        water.landscape = .water
        assert(moved.fingerprintText != object.fingerprintText && water.fingerprintText != landscape.fingerprintText,
               "another click or category is another mask")
        assert(object.kind.isAutomatic && landscape.kind.isAutomatic && landscape.title == LandscapeCategory.mountains.title
               && object.withoutAdjustments.prompt == object.prompt && landscape.withoutAdjustments.landscape == .mountains,
               "both are found in the photo, can be refined with the brush, and keep what they select when reset")
        let crowded = (0..<20).reduce(ObjectPrompt()) { $0.adding(CGPoint(x: Double($1) / 20, y: 0.5), include: true) }
        assert(crowded.points.count == ObjectPrompt.maxPoints && crowded.points.last?.point.x == 0.95,
               "clicks past the model's limit replace the oldest")
    }

    /// Writes `image` to a temporary PNG, as a photo on disk.
    private static func pngFile(_ image: CGImage) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-aimask-\(UUID().uuidString).png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return url
    }

    /// `width` × `height`, filled by `draw` in a context whose y points up.
    private static func picture(_ width: Int, _ height: Int, _ draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: DevelopRenderer.outputColorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        draw(context)
        return context.makeImage()!
    }

    /// A mask's weights, rows from the top.
    private static func weights(_ mask: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: mask.width * mask.height)
        let context = CGContext(data: &bytes, width: mask.width, height: mask.height, bitsPerComponent: 8, bytesPerRow: mask.width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.draw(mask, in: CGRect(x: 0, y: 0, width: mask.width, height: mask.height))
        return bytes
    }

    /// How well `mask` covers what `inside` says (pixel x, y from the top), as intersection
    /// over union.
    private static func overlap(_ mask: CGImage, _ inside: (Int, Int) -> Bool) -> Double {
        let bytes = weights(mask)
        var both = 0, either = 0
        for y in 0..<mask.height {
            for x in 0..<mask.width {
                let a = bytes[y * mask.width + x] > 127, b = inside(x, y)
                if a && b { both += 1 }
                if a || b { either += 1 }
            }
        }
        return Double(both) / Double(max(either, 1))
    }

    private static func found(_ lookup: SemanticMasks.Lookup) -> SemanticMasks.Result? {
        if case .found(let result) = lookup { result } else { nil }
    }

    private static func checkLandscape() {
        let labels = SceneSegmentation.labels
        let named = SceneSegmentation.categoryLabels.values.flatMap { $0 }
        assert(labels.count > 100 && named.allSatisfy(labels.contains) && Set(named).count == named.count
               && Set(SceneSegmentation.categoryLabels.keys) == Set(LandscapeCategory.allCases),
               "every category names labels the model has, each label in one category")

        // a gray-blue top and a darker bottom; the model is told the bottom is sea
        let width = 300, height = 200
        let photo = picture(width, height) { context in
            context.setFillColor(red: 0.6, green: 0.7, blue: 0.85, alpha: 1)
            context.fill(CGRect(x: 0, y: 100, width: 300, height: 100))
            context.setFillColor(red: 0.15, green: 0.3, blue: 0.5, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 100))
        }
        let classified = SceneSegmentation.classify(photo)
        assert(classified.map { $0.width == 448 && $0.height == 448 && $0.classes.allSatisfy { Int($0) < labels.count } } == true,
               "the model labels every part of the photo")
        let url = pngFile(photo)
        defer { try? FileManager.default.removeItem(at: url) }
        let sea = UInt8(labels.firstIndex(of: "sea")!), sky = UInt8(labels.firstIndex(of: "sky (other)")!)
        SceneSegmentation.remember(SceneSegmentation.ClassMap(width: 448, height: 448,
                                                              classes: (0..<(448 * 448)).map { $0 / 448 < 224 ? sky : sea }), for: url)
        let water = found(SceneSegmentation.lookup(.water, url: url, isRaw: false))
        assert(water.map { abs($0.coverage - 0.5) < 0.05 && $0.centroid.y > 0.7 && overlap($0.mask) { _, y in y >= 100 } > 0.9 } == true,
               "the water mask is the part labeled sea, the bottom half")
        guard case .notFound = SceneSegmentation.lookup(.mountains, url: url, isRaw: false) else {
            return assertionFailure("a category the photo doesn't show has no mask")
        }

        // brightening the water leaves the rest of the photo alone
        var mask = LocalAdjustment(kind: .landscape)
        mask.landscape = .water
        mask.exposure = 1
        var settings = DevelopSettings()
        settings.masks = [mask]
        let source = DevelopRenderer.Source(url: url, isRaw: false, maxPixel: nil)!
        let plain = SemanticMasks.rgba(DevelopRenderer.render(source.image(DevelopSettings())!)!)!
        let edited = SemanticMasks.rgba(DevelopRenderer.render(source.image(settings)!)!)!
        func green(_ pixels: [UInt8], _ y: Int) -> Int { Int(pixels[(y * width + 150) * 4 + 1]) }
        assert(green(edited, 160) > green(plain, 160) + 20 && abs(green(edited, 40) - green(plain, 40)) <= 2,
               "the water brightens and the sky doesn't")
    }

    private static func checkObjects() {
        // gray, a red disc at (150, 120) with radius 60 and a blue box at x 420…520, y 220…340 (from the top)
        let width = 600, height = 400
        let photo = picture(width, height) { context in
            context.setFillColor(red: 0.55, green: 0.55, blue: 0.5, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(red: 0.85, green: 0.15, blue: 0.1, alpha: 1)
            context.fillEllipse(in: CGRect(x: 90, y: height - 180, width: 120, height: 120))
            context.setFillColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1)
            context.fill(CGRect(x: 420, y: height - 340, width: 100, height: 120))
        }
        func inDisc(_ x: Int, _ y: Int) -> Bool { hypot(Double(x) + 0.5 - 150, Double(y) + 0.5 - 120) <= 60 }
        func inBox(_ x: Int, _ y: Int) -> Bool { x >= 420 && x < 520 && y >= 220 && y < 340 }
        let url = pngFile(photo)
        defer { try? FileManager.default.removeItem(at: url) }
        func select(_ prompt: ObjectPrompt) -> SemanticMasks.Result? { found(ObjectSelection.lookup(prompt, url: url, isRaw: false)) }

        let clicked = select(ObjectPrompt(points: [.init(point: CGPoint(x: 150.0 / 600, y: 120.0 / 400))]))
        assert(clicked.map { overlap($0.mask, inDisc) > 0.9 && overlap($0.mask, inBox) == 0 } == true, "a click picks out the disc")
        let boxed = select(ObjectPrompt(box: CGRect(x: 400.0 / 600, y: 200.0 / 400, width: 140.0 / 600, height: 160.0 / 400)))
        assert(boxed.map { overlap($0.mask, inBox) > 0.9 && abs($0.centroid.x - 470.0 / 600) < 0.02 } == true,
               "a box picks out what's in it")
        guard case .notFound = ObjectSelection.lookup(ObjectPrompt(), url: url, isRaw: false) else {
            return assertionFailure("no box or click selects nothing")
        }

        // brightening the selected disc leaves the background alone
        var mask = LocalAdjustment(kind: .object)
        mask.prompt = ObjectPrompt(points: [.init(point: CGPoint(x: 150.0 / 600, y: 120.0 / 400))])
        mask.exposure = 1
        var settings = DevelopSettings()
        settings.masks = [mask]
        let source = DevelopRenderer.Source(url: url, isRaw: false, maxPixel: nil)!
        let plain = SemanticMasks.rgba(DevelopRenderer.render(source.image(DevelopSettings())!)!)!
        let edited = SemanticMasks.rgba(DevelopRenderer.render(source.image(settings)!)!)!
        func red(_ pixels: [UInt8], _ x: Int, _ y: Int) -> Int { Int(pixels[(y * width + x) * 4]) }
        func green(_ pixels: [UInt8], _ x: Int, _ y: Int) -> Int { Int(pixels[(y * width + x) * 4 + 1]) }
        assert(green(edited, 150, 120) > green(plain, 150, 120) + 10 && abs(red(edited, 320, 300) - red(plain, 320, 300)) <= 2,
               "the object brightens and the background doesn't")
    }
}
