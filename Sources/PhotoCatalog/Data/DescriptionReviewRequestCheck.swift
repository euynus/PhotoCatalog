import CoreGraphics
import Foundation
import ImageIO

enum DescriptionReviewRequestCheck {
    static func run() {
        MainActor.assumeIsolated {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("pc-description-request-\(UUID().uuidString)")
            let defaults = UserDefaults.standard
            let previous = ["pc_llm", "pc_autoWriteXMP"].map { ($0, defaults.object(forKey: $0)) }
            defer {
                for (key, value) in previous {
                    if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
                }
                try? FileManager.default.removeItem(at: root)
            }
            guard let server = StandInServer() else { return assertionFailure("Local description test server started") }
            defer { server.stop() }
            do {
                let store = try CatalogStore(packageURL: root.appendingPathComponent("requests.photolibrary"))
                let imageURL = root.appendingPathComponent("fixture.jpg")
                try writeImage(at: imageURL)
                let photos = (1...2).map { index in
                    Asset(id: "fixture-\(index)", pid: index, ori: "l", thumb: imageURL.path,
                          preview: imageURL.path, filename: "Fixture-\(index).jpg", type: "JPEG", isRaw: false,
                          folderId: "fixture", folderName: "Fixture", date: Date(timeIntervalSince1970: 0),
                          width: 16, height: 16, orientation: 1, camera: "PRIVATE_CAMERA", lens: "",
                          focal: 0, aperture: 0, shutter: "", iso: 0, colorSpace: "sRGB", fileMB: 0,
                          rating: 0, flag: .none, keywords: ["PRIVATE_KEYWORD"], title: "", caption: "",
                          location: "PRIVATE_PLACE", gps: (0, 0), status: .ready, importedAt: .now,
                          localPath: imageURL.path, isDemo: false)
                }
                try store.upsert(photos)
                let app = AppState.selfCheckFixture(store: store)
                app.runsBackgroundMaintenance = false
                app.autoWriteXMPSidecar = false
                app.assets = photos
                let config = LLMConfiguration(kind: .openAICompatible,
                    baseURL: "http://127.0.0.1:\(server.port)/v1", model: "consented-model")
                @MainActor func prepare(_ targets: [Asset], includeMetadata: Bool = false) {
                    app.discardDescriptionReview()
                    app.descriptionReviewContext = DescriptionReviewContext(configuration: config, key: nil,
                        chinese: false, catalog: store, catalogGeneration: app.catalogLoadGeneration)
                    app.describeOptions = .init(includeMetadata: includeMetadata)
                    app.describeTargets = targets
                }
                server.reply = (200, #"{"choices":[{"message":{"content":"{\"title\":\"Reviewed title\",\"caption\":\"Reviewed caption\",\"keywords\":[\"new\"]}"}}]}"#)
                prepare(photos)
                app.describePhotos()
                app.llmConfiguration = .init(kind: .openAICompatible,
                    baseURL: "https://example.invalid/v1", model: "unconsented-model")
                app.describeOptions.includeMetadata = true
                waitForBatch(app)
                assert(server.count == 2 && app.descriptionReview?.successfulItems.count == 2,
                       "the actual batch sends both synthetic previews to the consented local service")
                let request = try JSONSerialization.jsonObject(with: server.last!.body) as! [String: Any]
                let sent = String(decoding: server.last!.body, as: UTF8.self)
                assert(request["model"] as? String == "consented-model"
                       && !sent.contains("PRIVATE_CAMERA") && !sent.contains("PRIVATE_PLACE") && !sent.contains("PRIVATE_KEYWORD"),
                       "changing settings mid-batch cannot redirect requests or expand metadata consent")
                let beforeApply = try store.loadAssets()
                assert(app.assets.allSatisfy { $0.title.isEmpty } && beforeApply.allSatisfy { $0.title.isEmpty }
                       && app.descriptionReview?.selectedIDs.isEmpty == true,
                       "actual network replies remain unselected proposals without automatic catalog writes")
                let completed = app.backgroundTasks.first { $0.kind == .ai }!
                assert(completed.state == .completed && completed.succeededCount == 2
                       && app.taskCenterActions(completed).review != nil && app.taskCenterActions(completed).retry == nil,
                       "successful generation exposes review, not an automatic resend action")
                app.sheet = nil
                app.taskCenterActions(completed).review?()
                assert(app.sheet == "descriptionReview", "task history can reopen the retained review")
                app.descriptionReview?.setSelected(true, for: photos[0].id)
                assert(app.applyReviewedDescriptions(app.descriptionReview!.selectedDescriptions),
                       "explicit selection applies a real generated result")
                let saved = try store.loadAssets()
                assert(saved.first { $0.id == photos[0].id }?.title == "Reviewed title"
                       && saved.first { $0.id == photos[1].id }?.title == "",
                       "applying a generated proposal leaves unselected photos untouched")

                prepare([photos[1]], includeMetadata: true)
                assert(app.taskCenterActions(completed).review == nil,
                       "discarding a batch removes its obsolete review action")
                app.describePhotos()
                waitForBatch(app)
                let optedIn = String(decoding: server.last!.body, as: UTF8.self)
                assert(server.count == 3 && optedIn.contains("PRIVATE_CAMERA")
                       && optedIn.contains("PRIVATE_PLACE") && optedIn.contains("PRIVATE_KEYWORD"),
                       "explicit metadata consent is honored by the actual request")

                prepare(photos)
                app.describePhotos()
                app.cancelDescribePhotos()
                waitForBatch(app)
                assert(server.count == 3 && app.descriptionReview?.failedItems.count == photos.count
                       && app.backgroundTasks.first { $0.kind == .ai }?.state == .cancelled,
                       "cancellation before work starts sends nothing and retains retryable items")

                server.reply = (401, "PRIVATE_SERVER_RESPONSE_DO_NOT_PERSIST")
                prepare([photos[1]])
                app.describePhotos()
                waitForBatch(app)
                let failed = app.backgroundTasks.first { $0.kind == .ai }!
                let history = try Data(contentsOf: app.taskHistory!.fileURL)
                assert(failed.state == .failed && failed.failedCount == 1
                       && app.descriptionReview?.failedItems.count == 1,
                       "a service rejection becomes a visible failure rather than a completed description")
                assert(!String(decoding: history, as: UTF8.self).contains("PRIVATE_SERVER_RESPONSE_DO_NOT_PERSIST"),
                       "raw service responses are not persisted in task history")
                print("--- description request workflow assertions passed ---")
            } catch {
                assertionFailure("Description request workflow check failed: \(error)")
            }
        }
    }

    @MainActor
    private static func waitForBatch(_ app: AppState) {
        let deadline = Date().addingTimeInterval(30)
        while app.describeProgress != nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        assert(app.describeProgress == nil, "description batch completed before its deadline")
    }

    private static func writeImage(at url: URL) throws {
        guard let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
