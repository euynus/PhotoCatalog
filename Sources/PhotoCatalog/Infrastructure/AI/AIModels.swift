// ============================================================
//  AI models — the Core ML models the app bundles, compiled once
// ============================================================
import CoreML
import CryptoKit
import Foundation

/// The machine-learning models in `Resources/Models` (converted by `script/models/convert.py`),
/// each compiled the first time it's needed and kept compiled in Application Support, so later
/// launches load it directly. Everything runs on this Mac.
enum AIModels {
    enum Name: String, CaseIterable, Sendable {
        case superResolution = "SuperResolution"
        case denoise = "Denoise"
        case inpaint = "Inpaint"
        case depth = "Depth"

        /// Where the model runs fastest (measured on Apple silicon): the convolutional super
        /// resolution on the Neural Engine, the attention in the denoiser and LaMa's Fourier
        /// convolutions on the GPU (the Neural Engine is slower and, for LaMa, less precise).
        var computeUnits: MLComputeUnits {
            switch self {
            case .superResolution, .depth: .all
            case .denoise, .inpaint: .cpuAndGPU
            }
        }
    }

    /// Where the bundled packages are: the app's resources, or the repository's when running
    /// from a build folder.
    static var folder: URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Models"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Models")
        return FileManager.default.fileExists(atPath: repository.path) ? repository : nil
    }

    static func isAvailable(_ name: Name) -> Bool {
        folder.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("\(name.rawValue).mlpackage").path) } ?? false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded: [Name: MLModel] = [:]

    /// The model, compiled and loaded on first use; nil when it isn't bundled or won't load.
    static func model(_ name: Name) -> MLModel? {
        lock.withLock {
            if let model = loaded[name] { return model }
            guard let package = folder?.appendingPathComponent("\(name.rawValue).mlpackage"),
                  let compiled = compiledModel(package, name: name) else { return nil }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = name.computeUnits
            guard let model = try? MLModel(contentsOf: compiled, configuration: configuration) else { return nil }
            loaded[name] = model
            return model
        }
    }

    /// The package compiled, from the cache when this very package was compiled before.
    private static func compiledModel(_ package: URL, name: Name) -> URL? {
        let files = FileManager.default
        guard let digest = fingerprint(package) else { return nil }
        let cache = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoCatalog/Models", isDirectory: true)
        let target = cache.appendingPathComponent("\(name.rawValue)-\(digest).mlmodelc")
        if files.fileExists(atPath: target.path) { return target }
        guard let temporary = try? MLModel.compileModel(at: package) else { return nil }
        try? files.createDirectory(at: cache, withIntermediateDirectories: true)
        // older compilations of this model are no longer needed
        for old in (try? files.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix("\(name.rawValue)-") {
            try? files.removeItem(at: old)
        }
        guard (try? files.moveItem(at: temporary, to: target)) != nil else { return temporary }
        return target
    }

    /// A short digest of every file in the package, so a changed model is compiled again.
    private static func fingerprint(_ package: URL) -> String? {
        guard let enumerator = FileManager.default.enumerator(at: package, includingPropertiesForKeys: [.isRegularFileKey])
        else { return nil }
        var hasher = SHA256()
        let files = enumerator.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.path < $1.path }
        for file in files {
            hasher.update(data: Data(file.path.dropFirst(package.path.count).utf8))
            guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return nil }
            hasher.update(data: data)
        }
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
