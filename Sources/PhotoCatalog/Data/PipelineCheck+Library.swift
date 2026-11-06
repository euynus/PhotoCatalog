import Foundation
import ImageIO
import CoreGraphics

// Part of step 4 (persist + reload roundtrip): round trips through the app, each on a scratch
// catalog of its own with photos the reload returned.
extension PipelineCheck.Run {
    /// virtual copies: another entry for the same original, with its own settings and metadata,
    /// never taken for a duplicate, a RAW+JPEG pair or the file's owner
    func virtualCopyLifecycle(_ reloaded: [Asset]) {
        let virtualCopies: [String: Bool] = MainActor.assumeIsolated {
            var results: [String: Bool] = [:]
            // a scratch catalog and file of its own: renaming and removing must not touch the others
            let scratch = fm.temporaryDirectory.appendingPathComponent("pc-virtual-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: scratch) }
            try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            guard let sourcePath = reloaded[3].localPath,
                  let copyStore = try? CatalogStore(packageURL: scratch.appendingPathComponent("Copies.photolibrary"))
            else { return ["scratch catalog": false] }
            let scratchFile = scratch.appendingPathComponent(URL(fileURLWithPath: sourcePath).lastPathComponent)
            try? fm.copyItem(atPath: sourcePath, toPath: scratchFile.path)
            var master = reloaded[3]
            master.localPath = scratchFile.path
            try? copyStore.upsert([master])
            let store = copyStore
            let undo = UndoManager()
            undo.groupsByEvent = false
            let app = AppState.selfCheckFixture(store: store)
            app.runsBackgroundMaintenance = false
            app.undoManager = undo
            app.applyLoadedCatalogForScaleCheck([master], from: store)
            var edit = DevelopSettings()
            edit.exposure = 0.6
            undo.beginUndoGrouping(); app.commitDevelop([master.id: edit], undoName: "edit"); undo.endUndoGrouping()
            app.selectedIds = [master.id]
            app.setPrimary(master.id)
            undo.beginUndoGrouping(); app.createVirtualCopies(); undo.endUndoGrouping()
            guard let copy = app.assets.first(where: { $0.masterId == master.id && !$0.deleted }) else { return ["created": false] }
            results["created"] = copy.localPath == master.localPath && copy.copyName != nil && copy.id != master.id
                && app.developSettings[copy.id] == edit && app.selectedIds == [copy.id] && !copy.isDemo
            var blackAndWhite = edit
            blackAndWhite.saturation = -100
            undo.beginUndoGrouping(); app.commitDevelop([copy.id: blackAndWhite], undoName: "bw"); undo.endUndoGrouping()
            undo.beginUndoGrouping(); _ = app.applyRatingShortcut(4); undo.endUndoGrouping()
            let reopened = AppState.selfCheckFixture(store: store)
            reopened.runsBackgroundMaintenance = false
            reopened.applyLoadedCatalogForScaleCheck((try? store.loadAssets()) ?? [], from: store)
            let reopenedCopy = reopened.assets.first { $0.id == copy.id }
            let reopenedMaster = reopened.assets.first { $0.id == master.id }
            results["independent"] = reopenedCopy?.masterId == master.id && reopenedCopy?.copyName == copy.copyName
                && reopened.developSettings[copy.id] == blackAndWhite && reopened.developSettings[master.id] == edit
                && reopenedCopy?.rating == 4 && reopenedMaster?.rating == master.rating
            results["not a pair or owner"] = AssetPairing.rawJpeg(app.assets).primaryByCompanion[copy.id] == nil
                && AssetPairing.rawJpeg(app.assets).companionsByPrimary[copy.id] == nil
                && app.fileOwners([copy, master]).map(\.id) == [master.id]
            // renaming the original through the copy moves the master and carries the path to the copy
            app.selectedIds = [copy.id]
            app.setPrimary(copy.id)
            let renamed = RenameService.renameWithTemplate(app.fileOwners([copy]), template: "vc_{seq}", companions: [:])
            _ = app.applyMovedOriginalLocations(renamed)
            let movedMaster = app.assets.first { $0.id == master.id }, movedCopy = app.assets.first { $0.id == copy.id }
            results["file changes follow"] = renamed[master.id] != nil && movedCopy?.localPath == movedMaster?.localPath
                && movedCopy?.filename == movedMaster?.filename && renamed[copy.id] == nil
            // removing the master takes its copy along; undo brings both back
            app.selectedIds = [master.id]
            app.setPrimary(master.id)
            undo.beginUndoGrouping(); app.removeSelected(); undo.endUndoGrouping()
            let bothRemoved = app.assets.first { $0.id == copy.id }?.deleted == true
                && app.assets.first { $0.id == master.id }?.deleted == true
            undo.undo()
            results["removed with master"] = bothRemoved && app.assets.first { $0.id == copy.id }?.deleted == false
            // undoing the creation removes the copy
            app.selectedIds = [master.id]
            app.setPrimary(master.id)
            undo.beginUndoGrouping(); app.createVirtualCopies(); undo.endUndoGrouping()
            let second = app.assets.first { $0.masterId == master.id && $0.id != copy.id }
            undo.undo()
            results["undo creation"] = second != nil && second?.copyName != copy.copyName
                && app.assets.first { $0.id == second?.id }?.deleted == true
            return results
        }
        for (name, passed) in virtualCopies.sorted(by: { $0.key < $1.key }) {
            check(passed, "virtual copies: \(name)")
        }
    }

    /// editing in another app: a 16-bit TIFF copy beside the untouched original, cataloged with
    /// the original's metadata and stacked with it
    func externalEditor(_ reloaded: [Asset]) {
        let externalEdit: [String: Bool] = MainActor.assumeIsolated {
            let scratch = fm.temporaryDirectory.appendingPathComponent("pc-edit-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: scratch) }
            try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            guard let sourcePath = reloaded[2].localPath,
                  let editStore = try? CatalogStore(packageURL: scratch.appendingPathComponent("Edit.photolibrary"))
            else { return ["scratch catalog": false] }
            let originalURL = scratch.appendingPathComponent("IMG_edit.jpg")
            try? fm.copyItem(atPath: sourcePath, toPath: originalURL.path)
            let originalBytes = try? Data(contentsOf: originalURL)
            var master = reloaded[2]
            master.localPath = originalURL.path
            master.filename = originalURL.lastPathComponent
            master.rating = 3
            master.keywords = ["harbor"]
            master.title = "Harbor"
            try? editStore.upsert([master])
            let app = AppState.selfCheckFixture(store: editStore)
            app.runsBackgroundMaintenance = false
            app.applyLoadedCatalogForScaleCheck([master], from: editStore)
            var look = DevelopSettings()
            look.exposure = 0.5
            app.commitDevelop([master.id: look], undoName: "look")
            for round in 0..<2 {
                let made = AppState.renderEditedCopies(app.externalEditJobs([master]),
                                                       coordinator: ImportCoordinator(store: editStore),
                                                       previewMaxPixel: 512)
                if round == 1, let seen = made.first?.asset {
                    // folder watching finds the new file before the edit finishes
                    try? editStore.upsert([seen])
                    app.applyLoadedCatalogForScaleCheck(app.assets + [seen], from: editStore)
                }
                app.finishExternalEdit(made, editor: nil, expected: 1)
            }
            let copies = app.assets.filter { $0.id != master.id && !$0.deleted }
            let first = copies.first
            let depth = first?.localPath.flatMap { CGImageSourceCreateWithURL(URL(fileURLWithPath: $0) as CFURL, nil) }
                .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }?[kCGImagePropertyDepth] as? Int
            return [
                "tiff beside the original": copies.count == 2
                    && copies.allSatisfy { ($0.localPath ?? "").hasPrefix(scratch.path) && $0.filename.hasSuffix(".tif")
                        && EditedVersions.originalStem(of: ($0.filename as NSString).deletingPathExtension) == "IMG_edit" }
                    && Set(copies.map(\.filename)).count == 2,
                "16-bit": depth == 16,
                "metadata carried": copies.allSatisfy { $0.rating == 3 && $0.keywords == ["harbor"] && $0.title == "Harbor"
                    && $0.folderId == master.folderId },
                "stacked with the original": first.flatMap { app.stackInfo(for: $0)?.count } == 3,
                "original untouched": (try? Data(contentsOf: originalURL)) == originalBytes,
            ]
        }
        for (name, passed) in externalEdit.sorted(by: { $0.key < $1.key }) {
            check(passed, "external editor: \(name)")
        }
    }

    /// sidecars another app changes: noticed, read on request (or automatically), never
    /// rewritten by the read, and our own writes don't count
    func externallyChangedSidecars(_ reloaded: [Asset]) {
        let externalXMP: [String: Bool] = MainActor.assumeIsolated {
            let scratch = fm.temporaryDirectory.appendingPathComponent("pc-xmp-\(UUID().uuidString)")
            let previousAutoRead = UserDefaults.app.object(forKey: "pc_autoReadChangedXMP")
            defer {
                try? fm.removeItem(at: scratch)
                UserDefaults.app.set(previousAutoRead, forKey: "pc_autoReadChangedXMP")
            }
            try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            guard let sourcePath = reloaded[4].localPath,
                  let xmpStore = try? CatalogStore(packageURL: scratch.appendingPathComponent("XMP.photolibrary"))
            else { return ["scratch catalog": false] }
            let originalURL = scratch.appendingPathComponent("IMG_xmp.jpg")
            try? fm.copyItem(atPath: sourcePath, toPath: originalURL.path)
            let sidecarURL = XMPSidecar.sidecarURL(for: originalURL)
            var photo = reloaded[4]
            photo.localPath = originalURL.path
            photo.rating = 1
            photo.keywords = ["mine"]
            XMPSidecar.write(photo, to: sidecarURL)
            try? xmpStore.upsert([photo])
            let app = AppState.selfCheckFixture(store: xmpStore)
            app.runsBackgroundMaintenance = false
            app.applyLoadedCatalogForScaleCheck([photo], from: xmpStore)
            app.checkExternalXMPChangesNow()
            var results: [String: Bool] = ["first sighting isn't a change": app.externallyChangedXMPIds.isEmpty]
            // another app rates, retags and titles the photo in its sidecar
            func otherAppEdits(rating: Int, keyword: String, secondsLater: Double) {
                var theirs = photo
                theirs.rating = rating
                theirs.keywords = [keyword]
                theirs.title = "From \(keyword)"
                XMPSidecar.write(theirs, to: sidecarURL)
                try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(secondsLater)],
                                      ofItemAtPath: sidecarURL.path)
            }
            otherAppEdits(rating: 4, keyword: "lr", secondsLater: 10)
            app.checkExternalXMPChangesNow()
            results["change noticed"] = app.externallyChangedXMPIds == [photo.id]
            let sidecarBefore = try? Data(contentsOf: sidecarURL)
            app.readMetadataFromFiles([photo.id])
            let read = app.assets.first { $0.id == photo.id }
            results["read from the file"] = read?.rating == 4 && read?.keywords == ["lr"] && read?.title == "From lr"
                && app.externallyChangedXMPIds.isEmpty
            results["the read leaves the sidecar alone"] = (try? Data(contentsOf: sidecarURL)) == sidecarBefore
            app.selectedIds = [photo.id]
            app.setPrimary(photo.id)
            _ = app.setRating(5)
            // the save is written in turn with the automatic writes: wait for it
            let saving = app.writeXMPForSelection()
            var saved = saving == nil
            Task { @MainActor in
                await saving?.value
                saved = true
            }
            let deadline = Date(timeIntervalSinceNow: 30)
            while !saved, Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
            results["the save is written"] = saved && XMPSidecar.read(sidecarURL)?.rating == 5
            app.checkExternalXMPChangesNow()
            results["our own write isn't a change"] = app.externallyChangedXMPIds.isEmpty
            // a sidecar put back with an older date is another version too
            otherAppEdits(rating: 3, keyword: "restored", secondsLater: -3600)
            app.checkExternalXMPChangesNow()
            results["an older sidecar is a change"] = app.externallyChangedXMPIds == [photo.id]
            // an automatic write leaves another app's change to be read first
            let before = try? Data(contentsOf: sidecarURL)
            var edited = app.assets.first { $0.id == photo.id } ?? photo
            edited.rating = 1
            let outcome = AutomaticXMPWriter.writeUnlessChanged(edited, baseline: app.xmpSyncTime(for: photo.id))
            results["automatic writes skip a sidecar changed elsewhere"] = outcome == .changedElsewhere
                && (try? Data(contentsOf: sidecarURL)) == before
            app.readMetadataFromFiles([photo.id])
            results["and write again once it's read"] =
                AutomaticXMPWriter.writeUnlessChanged(edited, baseline: app.xmpSyncTime(for: photo.id)) != .changedElsewhere
            app.readMetadataFromFiles([photo.id])
            let undo = UndoManager()
            undo.groupsByEvent = false
            app.undoManager = undo
            app.autoReadChangedXMP = true
            otherAppEdits(rating: 2, keyword: "bridge", secondsLater: 30)
            undo.beginUndoGrouping()
            app.checkExternalXMPChangesNow()
            undo.endUndoGrouping()
            let auto = app.assets.first { $0.id == photo.id }
            results["read automatically when asked to"] = auto?.rating == 2 && auto?.keywords == ["bridge"]
                && app.externallyChangedXMPIds.isEmpty
            if undo.canUndo { undo.undo() }
            results["undo doesn't take back a background read"] = app.assets.first { $0.id == photo.id }?.rating == 2
            app.undoManager = nil
            return results
        }
        for (name, passed) in externalXMP.sorted(by: { $0.key < $1.key }) {
            check(passed, "external XMP: \(name)")
        }
    }

    /// album sets: nest albums, smart albums and sets; deleting one moves its contents up
    func albumSetNesting(_ reloaded: [Asset]) {
        let albumSets: [String: Bool] = MainActor.assumeIsolated {
            let scratch = fm.temporaryDirectory.appendingPathComponent("pc-sets-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: scratch) }
            guard let setStore = try? CatalogStore(packageURL: scratch.appendingPathComponent("Sets.photolibrary"))
            else { return ["scratch catalog": false] }
            try? setStore.upsert(Array(reloaded.prefix(2)))
            try? setStore.saveAlbum(Album(id: "al-trip", name: "Trip", assetIds: reloaded.prefix(2).map(\.id)))
            let rawRule = SmartRule(match: "all", conditions: [SmartCondition(field: "type", op: "=", value: "CR3")])
            try? setStore.saveSmartAlbum(SmartAlbum(id: "sm-raw", name: "RAW", rule: rawRule, count: 0))
            let app = AppState.selfCheckFixture(store: setStore)
            app.runsBackgroundMaintenance = false
            app.applyLoadedCatalogForScaleCheck(Array(reloaded.prefix(2)), from: setStore)
            let outer = AlbumSet(id: "as-outer", name: "2026")
            let inner = AlbumSet(id: "as-inner", name: "Summer", parentId: "as-outer")
            try? setStore.saveAlbumSet(outer)
            try? setStore.saveAlbumSet(inner, sortOrder: 1)
            app.albumSets = [outer, inner]
            app.moveToAlbumSet("al-trip", setId: "as-inner")
            app.moveToAlbumSet("sm-raw", setId: "as-outer")
            app.moveToAlbumSet("as-outer", setId: "as-inner")   // into its own child: refused
            let reopened = AppState.selfCheckFixture(store: setStore)
            reopened.runsBackgroundMaintenance = false
            reopened.applyLoadedCatalogForScaleCheck(Array(reloaded.prefix(2)), from: setStore)
            let tree = CollectionNode.build(sets: reopened.albumSets, albums: reopened.albums, smart: reopened.smartAlbums)
            let outerChildren = tree.first { $0.id == "set:as-outer" }?.children?.map(\.id) ?? []
            let innerChildren = tree.first { $0.id == "set:as-outer" }?.children?
                .first { $0.id == "set:as-inner" }?.children?.map(\.id) ?? []
            var results: [String: Bool] = [
                "nesting persists": reopened.albums.first?.setId == "as-inner"
                    && reopened.smartAlbums.first?.setId == "as-outer"
                    && reopened.albumSets.first { $0.id == "as-outer" }?.parentId == nil,
                "sidebar tree": tree.map(\.id) == ["set:as-outer"] && outerChildren == ["set:as-inner", "smart:sm-raw"]
                    && innerChildren == ["album:al-trip"],
                "no set inside itself": app.albumSetChoices(for: "as-outer").isEmpty
                    && app.albumSetChoices(for: "al-trip").map(\.set.id) == ["as-outer", "as-inner"],
            ]
            try? setStore.deleteAlbumSet(id: "as-inner")
            let albumsAfter = (try? setStore.loadAlbums()) ?? []
            results["deleting a set moves its albums up"] = albumsAfter.first?.setId == "as-outer"
                && albumsAfter.first?.assetIds.count == 2
                && ((try? setStore.loadAlbumSets()) ?? []).map(\.id) == ["as-outer"]
            let looped = CollectionNode.build(sets: [AlbumSet(id: "a", name: "A", parentId: "b"),
                                                     AlbumSet(id: "b", name: "B", parentId: "a")], albums: [], smart: [])
            results["looped sets still show"] = looped.count == 1 && looped[0].children?.count == 1
            return results
        }
        for (name, passed) in albumSets.sorted(by: { $0.key < $1.key }) {
            check(passed, "album sets: \(name)")
        }
    }

    /// renaming photos: the preview matches what happens on disk and in the catalog
    func photoRenaming(_ reloaded: [Asset]) {
        let renaming: [String: Bool] = MainActor.assumeIsolated {
            let scratch = fm.temporaryDirectory.appendingPathComponent("pc-rename-\(UUID().uuidString)")
            let previousTemplate = UserDefaults.app.string(forKey: "pc_renameTemplate")
            defer {
                try? fm.removeItem(at: scratch)
                UserDefaults.app.set(previousTemplate, forKey: "pc_renameTemplate")
            }
            try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            guard let renameStore = try? CatalogStore(packageURL: scratch.appendingPathComponent("Rename.photolibrary"))
            else { return ["scratch catalog": false] }
            var photos: [Asset] = []
            for (index, title) in ["Harbor", "Harbor"].enumerated() {
                guard let sourcePath = reloaded[index].localPath else { return ["fixture": false] }
                let file = scratch.appendingPathComponent("IMG_\(index).jpg")
                try? fm.copyItem(atPath: sourcePath, toPath: file.path)
                var photo = reloaded[index]
                photo.localPath = file.path
                photo.filename = file.lastPathComponent
                photo.title = title
                photos.append(photo)
            }
            try? renameStore.upsert(photos)
            let app = AppState.selfCheckFixture(store: renameStore)
            app.runsBackgroundMaintenance = false
            app.applyLoadedCatalogForScaleCheck(photos, from: renameStore)
            app.selectedIds = Set(photos.map(\.id))
            let targets = app.renameTargets()
            let plan = RenameService.plan(targets, template: "{title}_{seq}", start: 7)
            let sameName = RenameService.plan(targets, template: "{title}", start: 1)
            app.renameOriginals(template: "{title}_{seq}", start: 7)
            let names = Set(app.assets.compactMap { $0.localPath.map { URL(fileURLWithPath: $0).lastPathComponent } })
            let reloadedNames = Set(((try? renameStore.loadAssets()) ?? []).map(\.filename))
            return [
                "preview": plan.names.map(\.to) == ["Harbor_0007.jpg", "Harbor_0008.jpg"] && plan.clashes == 0
                    && sameName.clashes == 1,
                "renamed on disk and in the catalog": names == ["Harbor_0007.jpg", "Harbor_0008.jpg"]
                    && reloadedNames == names
                    && names.allSatisfy { fm.fileExists(atPath: scratch.appendingPathComponent($0).path) },
                "template remembered": app.renameTemplate == "{title}_{seq}",
            ]
        }
        for (name, passed) in renaming.sorted(by: { $0.key < $1.key }) {
            check(passed, "rename photos: \(name)")
        }
    }
}
