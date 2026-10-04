import Foundation

/// Consent/review checks never send requests, read the keychain or load images.
enum DescriptionReviewCheck {
    static func run() {
        checkConsent()
        checkDestination()
        checkSelection()
        checkRetries()
        checkWorkflow()
        print("--- description review assertions passed ---")
    }

    private static func checkConsent() {
        let image = Data([0xFF, 0xD8, 0x01])
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let details = PhotoDescriber.Details(date: date, camera: "PRIVATE_CAMERA", place: "PRIVATE_PLACE",
                                             keywords: ["PRIVATE_KEYWORD", "another"])
        let previewOnly = PhotoDescriber.request(image: image, details: details, chinese: false)
        assert(!DescriptionReview.Options().includeMetadata, "metadata consent starts off")
        assert(previewOnly.prompt == "Describe this photo." && previewOnly.images == [image],
               "the default request carries only the preview and the generic description prompt")
        for value in ["PRIVATE_CAMERA", "PRIVATE_PLACE", "PRIVATE_KEYWORD", date.formatted(.iso8601.year().month().day())] {
            assert(!previewOnly.prompt.contains(value) && !previewOnly.system.contains(value),
                   "catalog metadata is absent without consent")
        }
        let optedIn = PhotoDescriber.request(image: image, details: details, chinese: true, includeMetadata: true)
        assert(optedIn.images == [image] && optedIn.system.contains("Simplified Chinese")
               && optedIn.prompt.contains("taken: \(date.formatted(.iso8601.year().month().day()))")
               && optedIn.prompt.contains("camera: PRIVATE_CAMERA") && optedIn.prompt.contains("place: PRIVATE_PLACE")
               && optedIn.prompt.contains("existing keywords: PRIVATE_KEYWORD, another"),
               "explicit opt-in includes each disclosed metadata field")
        assert(PhotoDescriber.request(image: image, details: details, chinese: false, includeMetadata: false).prompt
               == previewOnly.prompt, "turning opt-in off removes all hints")
        assert(PhotoDescriber.request(image: image, details: .init(), chinese: false, includeMetadata: true).prompt
               == previewOnly.prompt, "empty metadata does not add an empty hints section")
    }

    private static func checkDestination() {
        let openAI = LLMConfiguration(kind: .openAICompatible, baseURL: "https://api.openai.com/v1", model: " test-model ")
        let display = PhotoDescriber.Destination(configuration: openAI)
        assert(display.provider == "OpenAI" && display.model == "test-model"
               && display.endpoint == "https://api.openai.com/v1/chat/completions" && !display.isLoopback,
               "consent names the configured provider, model and endpoint")
        let secretURL = LLMConfiguration(kind: .openAICompatible,
                                         baseURL: "https://PRIVATE_USER:PRIVATE_PASSWORD@example.com:8443/v1?key=PRIVATE_TOKEN#PRIVATE_FRAGMENT",
                                         model: "private-model")
        let safe = PhotoDescriber.Destination(configuration: secretURL).endpoint ?? ""
        assert(safe.hasPrefix("https://example.com:8443/"), "the destination still identifies the actual host and port")
        for secret in ["PRIVATE_USER", "PRIVATE_PASSWORD", "PRIVATE_TOKEN", "PRIVATE_FRAGMENT"] {
            assert(!safe.contains(secret), "URL credentials and query/fragment secrets never enter the display")
        }
        let invalid = LLMConfiguration(baseURL: "not a service URL")
        assert(PhotoDescriber.Destination(configuration: invalid).endpoint == nil,
               "an invalid endpoint is not displayed as raw configuration text")
        for host in ["localhost", "localhost.", "127.0.0.1", "127.9.8.7", "[::1]", "[0:0:0:0:0:0:0:1]", "[::ffff:127.0.0.1]"] {
            let configuration = LLMConfiguration(kind: .openAICompatible, baseURL: "http://\(host):11434/v1")
            assert(PhotoDescriber.Destination(configuration: configuration).isLoopback,
                   "loopback endpoints are identified by their host, including IPv6")
        }
        for host in ["192.168.1.2", "example.com", "localhost.example.com", "[2001:db8::1]"] {
            let configuration = LLMConfiguration(kind: .openAICompatible, baseURL: "http://\(host):11434/v1")
            assert(!PhotoDescriber.Destination(configuration: configuration).isLoopback,
                   "a model name or Ollama port never makes a network host local")
        }
    }

    private static func checkSelection() {
        let first = asset("first", title: "Existing title", keywords: ["old"])
        let second = asset("second")
        let proposal = PhotoDescriber.Description(title: "Proposed title", caption: "Proposed caption", keywords: ["old", "new", "new"])
        var review = DescriptionReview(targets: [first, second, first])
        assert(review.items.map(\.id) == ["first", "second"] && review.pendingCount == 2,
               "one review row is kept for each photo, in target order")
        review.setSelected(true, for: first.id)
        assert(review.selectedIDs.isEmpty, "pending photos cannot be selected")
        review.record(descriptions: [first.id: proposal, second.id: proposal, "unknown": proposal])
        assert(review.selectedDescriptions.isEmpty && review.selectedIDs.isEmpty && review.items.count == 2,
               "a result is never accepted automatically and unknown result IDs are ignored")
        review.setSelected(true, for: first.id)
        let accepted = review.selectedDescriptions
        assert(accepted.count == 1 && accepted[first.id]?.title == "" && accepted[first.id]?.caption == proposal.caption
               && accepted[first.id]?.keywords == ["new"],
               "only the selected photo's enabled changes are offered; existing text and keywords are protected")
        assert(review.items.first?.existing.title == "Existing title" && first.title == "Existing title"
               && first.caption.isEmpty && first.keywords == ["old"],
               "reviewing and reading an apply payload never mutate the catalog snapshot or the original asset")
        review.setSelected(false, for: first.id)
        assert(review.selectedDescriptions.isEmpty, "deselecting removes the photo from the apply payload")
        review.selectAll(true)
        assert(Set(review.selectedDescriptions.keys) == [first.id, second.id], "select all includes applicable successes only")
        review.selectAll(false)
        assert(review.selectedIDs.isEmpty, "deselect all leaves proposals intact")

        var replace = DescriptionReview.Options()
        replace.replace = true
        replace.keywords = false
        replace.caption = false
        var replacement = DescriptionReview(targets: [first], options: replace)
        replacement.record(descriptions: [first.id: proposal])
        replacement.selectAll(true)
        assert(replacement.selectedDescriptions[first.id] == PhotoDescriber.Description(title: proposal.title, caption: "", keywords: []),
               "replacement and field options are reflected in the exact acceptance payload")
        replacement.record(descriptions: [first.id: PhotoDescriber.Description(title: "", caption: "", keywords: [])])
        replacement.selectAll(true)
        assert(replacement.selectedIDs.isEmpty, "empty proposals cannot erase existing values or be selected")

        var disabled = replace
        disabled.title = false
        assert(disabled.isEmpty, "all output fields can be disabled independently of metadata consent")
        var unchanged = DescriptionReview(targets: [first], options: disabled)
        unchanged.record(descriptions: [first.id: proposal])
        unchanged.selectAll(true)
        assert(unchanged.selectedDescriptions.isEmpty, "disabled fields cannot be accepted through select all")

        let filled = asset("filled", title: "Same title", caption: "Existing caption", keywords: ["old"])
        var noChanges = DescriptionReview(targets: [filled])
        noChanges.record(descriptions: [filled.id: .init(title: "Same title", caption: "New caption", keywords: ["old"])])
        noChanges.selectAll(true)
        assert(noChanges.selectableIDs.isEmpty && noChanges.selectedDescriptions.isEmpty,
               "unchanged keywords and preserved existing text do not create a no-op acceptance")

        let local = DescriptionReview.Item(asset: asset("local", thumb: "file:///tmp/preview%20one.jpg"))
        let remote = DescriptionReview.Item(asset: asset("remote", thumb: "https://example.com/image.jpg"))
        let fallback = DescriptionReview.Item(asset: asset("fallback", preview: "/tmp/existing-preview.jpg"))
        assert(local.previewPath == "/tmp/preview one.jpg" && remote.previewPath == nil
               && fallback.previewPath == "/tmp/existing-preview.jpg",
               "review holds only existing local cache paths, without downloading or retaining image payloads")
    }

    private static func checkRetries() {
        let photos = [asset("accepted"), asset("unselected"), asset("failed"), asset("still-failed")]
        let proposal = PhotoDescriber.Description(title: "Title", caption: "Caption", keywords: ["keyword"])
        var review = DescriptionReview(targets: photos)
        review.record(descriptions: ["accepted": proposal, "unselected": proposal],
                      failures: ["failed": "Temporary error", "still-failed": "Offline"])
        review.selectAll(true)
        assert(review.selectedIDs == ["accepted", "unselected"], "select all never includes failures")
        review.selectAll(false)
        review.setSelected(true, for: "failed")
        assert(review.selectedIDs.isEmpty, "failed rows cannot be included in application")
        review.setSelected(true, for: "accepted")
        review.removeApplied(["accepted", "failed", "unselected"])
        assert(review.items.map(\.id) == ["unselected", "failed", "still-failed"]
               && review.failedIDs == ["failed", "still-failed"] && review.selectedIDs.isEmpty,
               "acknowledging a write removes only selected successes, retaining unselected and failed photos")
        let beforeRetry = review
        _ = review.failedIDs
        assert(review == beforeRetry, "obtaining retry targets does not discard failures before the retry succeeds")
        review.setSelected(true, for: "unselected")
        review.record(failures: ["failed": "Retry also failed"])
        assert(review.failedItems.first?.failure == "Retry also failed"
               && review.failedIDs == ["failed", "still-failed"] && review.selectedIDs == ["unselected"],
               "a partial failed retry keeps every remaining failure and unrelated selections")
        review.record(descriptions: ["failed": proposal])
        assert(review.failedIDs == ["still-failed"] && review.items.first(where: { $0.id == "failed" })?.proposed == proposal
               && !review.selectedIDs.contains("failed"), "a recovered result requires explicit review again")
        review.record(descriptions: ["unselected": proposal])
        assert(review.selectedIDs.isEmpty, "a refreshed proposal clears any earlier acceptance selection")
        var interrupted = DescriptionReview(targets: photos)
        interrupted.record(descriptions: ["accepted": proposal], failures: ["failed": "Original failure"])
        interrupted.failPending("Cancelled before request")
        assert(interrupted.pendingCount == 0 && Set(interrupted.failedIDs) == ["unselected", "failed", "still-failed"]
               && interrupted.items.first(where: { $0.id == "failed" })?.failure == "Original failure",
               "unattempted photos become retryable after cancellation without losing successes or prior failures")
        interrupted.setSelected(true, for: "accepted")
        var edited = photos[0]
        edited.title = "New local edit"
        assert(interrupted.refreshExisting(from: [edited]) && interrupted.selectedIDs.isEmpty
               && interrupted.items[0].existing.title == edited.title && interrupted.items[0].proposed == proposal,
               "new local metadata is shown and requires a fresh selection while preserving the proposal")
        assert(!interrupted.refreshExisting(from: [edited]), "unchanged live metadata does not invalidate selection again")
        assert(photos.allSatisfy { $0.title.isEmpty && $0.caption.isEmpty && $0.keywords.isEmpty },
               "retry and acceptance bookkeeping never edit the input photos")
    }

    private static func asset(_ id: String, title: String = "", caption: String = "", keywords: [String] = [],
                              thumb: String = "", preview: String = "") -> Asset {
        Asset(id: id, pid: 0, ori: "l", thumb: thumb, preview: preview, filename: "\(id).jpg", type: "JPG", isRaw: false,
              folderId: "review-check", folderName: "review-check", date: Date(timeIntervalSince1970: 0),
              width: 100, height: 80, orientation: 1, camera: "", lens: "", focal: 0, aperture: 0, shutter: "", iso: 0,
              colorSpace: "sRGB", fileMB: 1, rating: 0, flag: .none, keywords: keywords, title: title, caption: caption,
              location: "", gps: (0, 0), status: .ready, importedAt: Date(timeIntervalSince1970: 0), isDemo: false)
    }
}
