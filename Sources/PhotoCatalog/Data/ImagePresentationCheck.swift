import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

/// Image selection and cancelled-result acceptance without views or a catalog.
enum ImagePresentationCheck {
    static func run() {
        MainActor.assumeIsolated {
            LLMCheck.run { await check() }
        }
        print("--- image presentation assertions passed ---")
    }

    @MainActor
    private static func check() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pc-image-presentation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let first = root.appendingPathComponent("first.png")
            let second = root.appendingPathComponent("second.png")
            guard let firstImage = writeImage(at: first, red: 1, blue: 0),
                  let secondImage = writeImage(at: second, red: 0, blue: 1) else {
                return assertionFailure("synthetic image fixtures were written")
            }
            await checkPreviews(first: first, second: second)
            await checkFaces(first: firstImage, second: secondImage)
        } catch {
            assertionFailure("image presentation fixture failed: \(error)")
        }
    }

    @MainActor
    private static func checkPreviews(first: URL, second: URL) async {
        let maxPixel = ThumbnailService.Kind.preview2048.maxPixel
        let generation = 7
        let firstKey = ThumbLoader.key(first.path, maxPixel: maxPixel, cacheGeneration: generation)
        let secondKey = ThumbLoader.key(second.path, maxPixel: maxPixel, cacheGeneration: generation)
        await ThumbLoader.prefetch(first.path, maxPixel: maxPixel, cacheGeneration: generation)
        guard let firstImage = ThumbLoader.cachedImage(forKey: firstKey) else {
            return assertionFailure("the synthetic first preview was decoded")
        }
        let loader = ThumbLoader()
        defer { loader.cancelAndRelease() }
        ZoomablePhoto.loadPreview(first.path, for: "first", cacheGeneration: generation, loader: loader)
        assert(loader.owner == "first" && loader.loadedKey == firstKey && loader.image === firstImage,
               "starting a preview load assigns its image and owner together")
        assert(ZoomablePhoto.previewImage(for: "first", verifiedKey: firstKey, loader: loader) === firstImage,
               "the matching loaded preview is displayed")
        var changes = 0
        let subscription = loader.objectWillChange.sink { changes += 1 }
        ZoomablePhoto.loadPreview(first.path, for: "same-source", cacheGeneration: generation, loader: loader)
        subscription.cancel()
        assert(changes > 0 && ZoomablePhoto.previewImage(for: "same-source", verifiedKey: nil, loader: loader) === firstImage,
               "a same-source owner change redraws even when the loader skips reloading")
        ZoomablePhoto.loadPreview(first.path, for: "first", cacheGeneration: generation, loader: loader)
        assert(ZoomablePhoto.previewImage(for: "first", verifiedKey: nil, loader: loader) === firstImage,
               "an unresolved source may retain its own photo")
        assert(ZoomablePhoto.previewImage(for: "second", verifiedKey: nil, loader: loader) == nil,
               "a new asset cannot display the old image while its source is resolving")
        assert(ZoomablePhoto.previewImage(for: "second", verifiedKey: secondKey, loader: loader) == nil,
               "a verified but uncached target cannot display the old image")
        assert(ZoomablePhoto.previewImage(for: "first", verifiedKey: secondKey, loader: loader) == nil,
               "a verified key mismatch rejects the image even when its owner matches")
        let nextGenerationKey = ThumbLoader.key(first.path, maxPixel: maxPixel, cacheGeneration: generation + 1)
        assert(ZoomablePhoto.previewImage(for: "first", verifiedKey: nextGenerationKey, loader: loader) == nil,
               "a verified key from another cache generation rejects the old image")

        await ThumbLoader.prefetch(second.path, maxPixel: maxPixel, cacheGeneration: generation)
        guard let secondImage = ThumbLoader.cachedImage(forKey: secondKey) else {
            return assertionFailure("the synthetic second preview was decoded")
        }
        assert(ZoomablePhoto.previewImage(for: "second", verifiedKey: secondKey, loader: loader) === secondImage,
               "a cached target displays immediately, before its view task starts loading")
        assert(loader.owner == "first" && loader.image === firstImage,
               "selecting a cached target does not relabel the old loader image")
        ZoomablePhoto.loadPreview(second.path, for: "second", cacheGeneration: generation, loader: loader)
        assert(loader.owner == "second" && loader.loadedKey == secondKey && loader.image === secondImage,
               "the next load adopts the target image and owner together")
        assert(ZoomablePhoto.previewImage(for: "first", verifiedKey: nil, loader: loader) == nil,
               "the same ownership check applies when navigating back")

        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            ZoomablePhoto.loadPreview(first.path, for: "first", cacheGeneration: generation, loader: loader)
        }
        await cancelled.value
        assert(loader.owner == "second" && loader.loadedKey == secondKey && loader.image === secondImage,
               "a cancelled task cannot start a load or relabel the current image")

        loader.image = nil
        assert(ZoomablePhoto.previewImage(for: "second", verifiedKey: secondKey, loader: loader) === secondImage,
               "a warmed target cache is usable even while its matching loader has no image")
    }

    @MainActor
    private static func checkFaces(first: CGImage, second: CGImage) async {
        var state = FaceAvatar.ImageState()
        state.accept(first, for: "first")
        assert(state.image(for: "first") === first, "an avatar displays its accepted crop")
        assert(state.image(for: "second") == nil,
               "a changed face identity hides the old crop before the replacement task starts")
        state.clear()
        assert(state.image(for: "first") == nil && state.image(for: "second") == nil,
               "clearing before a missing-data return leaves no previous avatar")
        state.accept(second, for: "second")

        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            state.accept(first, for: "first")
            assert(state.image(for: "second") === second,
                   "a cancelled old crop cannot overwrite the replacement avatar")
            state.accept(nil, for: "first")
        }
        await cancelled.value
        assert(state.image(for: "second") === second && state.image(for: "first") == nil,
               "a cancelled empty result cannot erase the replacement avatar either")
        state.accept(nil, for: "second")
        assert(state.image(for: "second") == nil, "a current failed crop displays the placeholder")
    }

    private static func writeImage(at url: URL, red: CGFloat, blue: CGFloat) -> CGImage? {
        guard let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(red: red, green: 0, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString,
                                                               1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? image : nil
    }
}
