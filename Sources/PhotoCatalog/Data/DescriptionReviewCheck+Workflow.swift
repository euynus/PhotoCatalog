import Foundation

extension DescriptionReviewCheck {
    /// Scratch-catalog checks; no service requests, keychain access or image loading.
    static func checkWorkflow() {
        MainActor.assumeIsolated {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("pc-description-review-\(UUID().uuidString)")
            let defaults = UserDefaults.standard
            let oldXMP = defaults.object(forKey: "pc_autoWriteXMP")
            defer {
                if let oldXMP { defaults.set(oldXMP, forKey: "pc_autoWriteXMP") }
                else { defaults.removeObject(forKey: "pc_autoWriteXMP") }
                try? FileManager.default.removeItem(at: root)
            }
            do {
                let store = try CatalogStore(packageURL: root.appendingPathComponent("first.photolibrary"))
                let photos = Array(DemoData.assets.prefix(4)).map { source in
                    var asset = source
                    asset.isDemo = false
                    asset.deleted = false
                    asset.title = ""
                    asset.caption = ""
                    asset.keywords = []
                    asset.localPath = nil
                    return asset
                }
                assert(photos.count == 4, "the workflow fixture has four independent IDs")
                try store.upsert(photos)
                let app = AppState.selfCheckFixture(store: store)
                app.autoWriteXMPSidecar = false
                app.assets = photos
                let configuration = LLMConfiguration(kind: .openAICompatible,
                                                     baseURL: "https://example.invalid/v1", model: "check-model")
                let context = DescriptionReviewContext(configuration: configuration, key: "CHECK_ONLY_NEVER_SENT",
                                                       chinese: false, catalog: store,
                                                       catalogGeneration: app.catalogLoadGeneration)
                let proposal = PhotoDescriber.Description(title: "Proposed title", caption: "Proposed caption", keywords: ["new"])
                var review = DescriptionReview(targets: photos)
                review.record(descriptions: [photos[0].id: proposal, photos[1].id: proposal, photos[2].id: proposal],
                              failures: [photos[3].id: "Try again"])
                app.descriptionReviewContext = context
                app.descriptionReview = review
                assert(app.hasDescriptionReview && app.describeProgress == nil,
                       "completed proposals remain available for explicit review")
                let reviewTask = BackgroundTask(kind: .ai, title: "AI descriptions", state: .failed)
                var reviewOpens = 0
                app.recordBackgroundTask(reviewTask, originHistory: app.taskHistory!,
                                         actions: .init(review: { reviewOpens += 1 }))
                let openReview = app.taskCenterActions(reviewTask).review
                assert(openReview != nil, "a completed batch with retained results offers review")
                app.describeProgress = (0, 1)
                assert(app.hasDescriptionReview && app.taskCenterActions(reviewTask).review == nil,
                       "a prior batch cannot offer review while its failed items are being retried")
                openReview?()
                assert(reviewOpens == 0, "a callback obtained before retry rechecks the current review capability")
                app.describeProgress = nil
                app.taskCenterActions(reviewTask).review?()
                assert(reviewOpens == 1, "review becomes available again after retry without replacing the old callback")
                app.descriptionReviewContext = nil
                assert(app.taskCenterActions(reviewTask).review == nil,
                       "retained results without a current review context cannot offer a review action")
                app.descriptionReviewContext = context

                let beforeApply = try store.loadAssets()
                assert(app.assets.allSatisfy { $0.title.isEmpty && $0.caption.isEmpty && $0.keywords.isEmpty }
                       && beforeApply.allSatisfy { $0.title.isEmpty && $0.caption.isEmpty && $0.keywords.isEmpty },
                       "receiving proposals does not edit memory or persistent catalog metadata")

                app.descriptionReview?.setSelected(true, for: photos[0].id)
                let firstPayload = app.descriptionReview!.selectedDescriptions
                assert(!app.applyReviewedDescriptions([photos[1].id: proposal]), "unselected IDs cannot be applied")
                var altered = proposal
                altered.title = "Not the reviewed result"
                assert(!app.applyReviewedDescriptions([photos[0].id: altered]), "stale or forged payloads cannot be applied")
                let selectedBeforeFailure = app.descriptionReview
                try store.db.execChecked("""
                    CREATE TRIGGER description_review_reject BEFORE INSERT ON assets
                    BEGIN SELECT RAISE(ABORT, 'description review check failure'); END;
                    """)
                assert(!app.applyReviewedDescriptions(firstPayload), "a failed catalog transaction is not reported as applied")
                assert(app.descriptionReview == selectedBeforeFailure && app.asset(id: photos[0].id)?.title == "",
                       "failed persistence retains the exact proposals and selection without changing live metadata")
                let afterFailure = try store.loadAssets()
                assert(afterFailure.allSatisfy { $0.title.isEmpty }, "failed writes leave persistent metadata unchanged")
                try store.db.execChecked("DROP TRIGGER description_review_reject;")

                assert(app.applyReviewedDescriptions(firstPayload), "the retained selection can be applied after the database recovers")
                let afterApply = try store.loadAssets()
                let appliedPhoto = app.asset(id: photos[0].id)
                let savedPhoto = afterApply.first { $0.id == photos[0].id }
                assert(appliedPhoto?.title == proposal.title && savedPhoto?.title == proposal.title
                       && appliedPhoto?.caption == proposal.caption && savedPhoto?.caption == proposal.caption
                       && appliedPhoto?.keywords == proposal.keywords && savedPhoto?.keywords == proposal.keywords
                       && afterApply.first(where: { $0.id == photos[1].id })?.title == ""
                       && app.descriptionReview?.items.count == 3 && app.descriptionReview?.failedIDs == [photos[3].id],
                       "only selected photos persist, and unselected results and failures remain reviewable")

                app.descriptionReview?.setSelected(true, for: photos[1].id)
                let deletedPayload = app.descriptionReview!.selectedDescriptions
                assert(app.mutate([photos[1].id], writingSidecars: false) { $0.deleted = true })
                assert(!app.applyReviewedDescriptions(deletedPayload)
                       && app.asset(id: photos[1].id)?.title == ""
                       && app.descriptionReview?.failedIDs.contains(photos[1].id) == true,
                       "a photo deleted after generation is not modified or silently marked applied")

                app.descriptionReview?.setSelected(true, for: photos[2].id)
                let beforeLocalEdit = app.descriptionReview!.selectedDescriptions
                assert(app.mutate([photos[2].id], writingSidecars: false) { $0.title = "Local title written during review" })
                assert(!app.applyReviewedDescriptions(beforeLocalEdit)
                       && app.asset(id: photos[2].id)?.title == "Local title written during review"
                       && app.descriptionReview?.selectedIDs.contains(photos[2].id) == false
                       && app.descriptionReview?.items.first(where: { $0.id == photos[2].id })?.proposed == proposal,
                       "new local edits require a fresh review selection without discarding the AI proposal")
                app.descriptionReview?.setSelected(true, for: photos[2].id)
                let refreshedPayload = app.descriptionReview!.selectedDescriptions
                assert(refreshedPayload[photos[2].id]?.title == "" && app.applyReviewedDescriptions(refreshedPayload)
                       && app.asset(id: photos[2].id)?.title == "Local title written during review",
                       "fill-empty policy is recalculated against the latest metadata")

                assert(!context.matches(store: store, generation: app.catalogLoadGeneration + 1, isLoading: false)
                       && !context.matches(store: store, generation: app.catalogLoadGeneration, isLoading: true),
                       "a new catalog generation or loading phase invalidates old consent")
                let reopened = try CatalogStore(packageURL: store.packageURL)
                assert(!context.matches(store: reopened, generation: app.catalogLoadGeneration, isLoading: false),
                       "reopening the same path is a different catalog session")
                let otherStore = try CatalogStore(packageURL: root.appendingPathComponent("second.photolibrary"))
                try otherStore.upsert(photos)
                let otherApp = AppState.selfCheckFixture(store: otherStore)
                otherApp.autoWriteXMPSidecar = false
                otherApp.assets = photos
                otherApp.descriptionReviewContext = context
                review.selectAll(true)
                otherApp.descriptionReview = review
                assert(!otherApp.hasDescriptionReview && !otherApp.applyReviewedDescriptions(review.selectedDescriptions),
                       "identical asset IDs in another library cannot accept results from the original catalog")
                let otherContents = try otherStore.loadAssets()
                assert(otherContents.allSatisfy { $0.title.isEmpty }, "old results leave the other catalog untouched")

                let beforeDiscard = try store.loadAssets()
                app.discardDescriptionReview()
                assert(context.isInvalidated && app.descriptionReview == nil && app.descriptionReviewContext == nil
                       && app.describeProgress == nil && app.describeTargets.isEmpty,
                       "discard invalidates late callbacks and clears only transient review state")
                let afterDiscard = try store.loadAssets()
                assert(afterDiscard.map(\.title) == beforeDiscard.map(\.title),
                       "discarding the remaining proposals makes no catalog changes")

                let acceptedPhotos = [app.asset(id: photos[0].id)!, app.asset(id: photos[2].id)!]
                let addition = PhotoDescriber.Description(title: "Do not replace title", caption: "Do not replace caption",
                                                          keywords: ["new", "additional"])
                let additions = Dictionary(uniqueKeysWithValues: acceptedPhotos.map { ($0.id, addition) })
                var appendReview = DescriptionReview(targets: acceptedPhotos)
                appendReview.record(descriptions: additions)
                app.descriptionReviewContext = DescriptionReviewContext(configuration: configuration, key: nil,
                    chinese: false, catalog: store, catalogGeneration: app.catalogLoadGeneration)
                app.descriptionReview = appendReview
                assert(app.hasDescriptionReview && app.descriptionReview?.selectedIDs.isEmpty == true
                       && !app.applyReviewedDescriptions(additions),
                       "a new proposal batch cannot append keywords without explicit acceptance")
                let beforeAcceptance = try store.loadAssets()
                for photo in acceptedPhotos {
                    assert(app.asset(id: photo.id)?.keywords == photo.keywords
                           && beforeAcceptance.first(where: { $0.id == photo.id })?.keywords == photo.keywords,
                           "unselected proposals leave both live and persistent keywords unchanged")
                }
                app.descriptionReview?.selectAll(true)
                let appendPayload = app.descriptionReview!.selectedDescriptions
                assert(appendPayload.count == 2 && app.applyReviewedDescriptions(appendPayload),
                       "both explicitly selected photos accept their applicable changes")
                let appended = try store.loadAssets()
                for photo in acceptedPhotos {
                    let live = app.asset(id: photo.id)
                    let saved = appended.first { $0.id == photo.id }
                    assert(live?.keywords == ["new", "additional"] && saved?.keywords == live?.keywords
                           && live?.title == photo.title && saved?.title == photo.title
                           && live?.caption == photo.caption && saved?.caption == photo.caption,
                           "accepted descriptions append keywords once and preserve existing titles and captions")
                }

                let replacementPhoto = app.asset(id: photos[2].id)!
                var options = DescriptionReview.Options()
                options.replace = true
                options.keywords = false
                let replacement = PhotoDescriber.Description(title: "Replacement title", caption: "", keywords: ["ignored"])
                var replaceReview = DescriptionReview(targets: [replacementPhoto], options: options)
                replaceReview.record(descriptions: [replacementPhoto.id: replacement])
                replaceReview.setSelected(true, for: replacementPhoto.id)
                app.descriptionReviewContext = DescriptionReviewContext(configuration: configuration, key: nil,
                    chinese: false, catalog: store, catalogGeneration: app.catalogLoadGeneration)
                app.descriptionReview = replaceReview
                assert(app.applyReviewedDescriptions(replaceReview.selectedDescriptions),
                       "an explicitly accepted replacement uses the reviewed field options")
                let replaced = try store.loadAssets().first { $0.id == replacementPhoto.id }
                let liveReplacement = app.asset(id: replacementPhoto.id)
                assert(liveReplacement?.title == replacement.title && replaced?.title == replacement.title
                       && liveReplacement?.caption == replacementPhoto.caption && replaced?.caption == replacementPhoto.caption
                       && liveReplacement?.keywords == replacementPhoto.keywords && replaced?.keywords == replacementPhoto.keywords,
                       "replacement preserves empty proposal fields and leaves disabled keywords unchanged")
            } catch {
                assertionFailure("description workflow check failed: \(error)")
            }
        }
    }
}
