import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

extension DevelopCheck {
    static func checkPersistence() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pc-develop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let store = try CatalogStore(packageURL: directory.appendingPathComponent("Develop.photolibrary"))
            var edit = DevelopSettings()
            edit.exposure = 0.7
            edit.temperature = 4800
            try store.saveDevelopSettings(["a": edit, "b": edit])
            let saved = try store.loadDevelopSettings()
            assert(saved == ["a": edit, "b": edit], "adjustments round-trip")
            try store.saveDevelopSettings(["a": .neutral])
            let cleared = try store.loadDevelopSettings()
            assert(cleared == ["b": edit], "neutral settings delete the stored edit")

            // history: steps in order, the newest taken away by an undo, the oldest dropped at the limit
            try store.appendDevelopHistory(["a": (name: "one", settings: edit)])
            var second = edit
            second.contrast = 20
            try store.appendDevelopHistory(["a": (name: "two", settings: second)])
            var steps = try store.loadDevelopHistory("a")
            assert(steps.map(\.name) == ["one", "two"] && steps.last?.settings == second, "history steps round-trip in order")
            try store.removeLastDevelopHistory(["a"])
            steps = try store.loadDevelopHistory("a")
            assert(steps.map(\.name) == ["one"], "an undone edit's step is taken away")
            for n in 0..<(DevelopHistoryStep.limit + 5) {
                try store.appendDevelopHistory(["c": (name: "step \(n)", settings: edit)])
            }
            steps = try store.loadDevelopHistory("c")
            assert(steps.count == DevelopHistoryStep.limit && steps.first?.name == "step 5", "history keeps the newest steps")
            try store.clearDevelopHistory("c")
            let clearedHistory = try store.loadDevelopHistory("c")
            assert(clearedHistory.isEmpty, "history clears")

            var snapshot = DevelopSnapshot(id: "s1", name: "Warm", date: .now, settings: edit)
            try store.saveDevelopSnapshot(snapshot, for: "a")
            snapshot.name = "Warmer"
            try store.saveDevelopSnapshot(snapshot, for: "a")
            try store.saveDevelopSnapshot(DevelopSnapshot(id: "s2", name: "Other", date: .now, settings: .neutral), for: "b")
            let named = try store.loadDevelopSnapshots("a").map(\.name)
            assert(named == ["Warmer"], "snapshots save, rename and stay per photo")
            try store.deleteDevelopSnapshot("s1")
            let remaining = try store.loadDevelopSnapshots("a")
            assert(remaining.isEmpty, "snapshots delete")
        } catch {
            preconditionFailure("develop persistence check failed: \(error)")
        }
    }

    @MainActor
    static func checkEditsAndUndo() {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let app = AppState.selfCheckFixture()
        app.undoManager = undo
        var edit = DevelopSettings()
        edit.exposure = 1.2

        app.updateDevelopDraft(edit, for: "x")
        assert(app.developSettings(for: "x") == edit && app.developSettings["x"] == nil,
               "a drag previews without saving")
        undo.beginUndoGrouping()
        app.commitDevelop(["x": edit], undoName: "调整曝光度")
        undo.endUndoGrouping()
        assert(app.developSettings["x"] == edit && app.developDraft == nil, "release saves the edit")
        undo.undo()
        assert(app.developSettings["x"] == nil, "undo returns the photo to as shot")
        undo.redo()
        assert(app.developSettings["x"] == edit, "redo reapplies the edit")

        app.view = .grid
        _ = app.handleKey("d", hasCommand: false)
        assert(app.view == .develop, "D opens Develop")
        _ = app.handleKey("\\", hasCommand: false)
        assert(app.developShowsOriginal, "\\ shows the photo before adjustments")
        _ = app.handleKey("y", hasCommand: false)
        assert(app.developComparing && !app.developShowsOriginal, "Y puts before and after side by side")
        app.developCropping = true
        assert(!app.developComparing, "a tool ends the comparison")
        app.developCropping = false
        app.developComparing = true
        _ = app.handleKey("z", hasCommand: false)
        assert(app.loupeZoom == nil && app.developComparing, "zoom stays off while comparing")
        _ = app.handleKey("escape", hasCommand: false)
        assert(!app.developComparing && app.view == .develop, "Esc ends the comparison and stays in Develop")
        app.developShowsOriginal = true

        app.view = .grid
        _ = app.handleKey("r", hasCommand: false)
        assert(app.view == .develop && app.developCropping, "R opens the crop tool from anywhere")
        _ = app.handleKey("escape", hasCommand: false)
        assert(app.view == .develop && !app.developCropping, "Esc closes the crop tool but stays in Develop")
        _ = app.handleKey("r", hasCommand: false)
        app.view = .grid
        assert(!app.developCropping, "leaving Develop closes the crop tool")

        // masks: saved and selected when drawn; in the tool, Delete removes the selected mask
        // and never the photo, and Esc disarms a gradient before it closes the tool
        app.view = .develop
        app.primaryId = "x"
        var mask = LocalAdjustment(kind: .radial)
        mask.exposure = 0.5
        undo.beginUndoGrouping()
        app.addMask(mask, to: "x")
        undo.endUndoGrouping()
        assert(app.developSettings["x"]?.masks.map(\.id) == [mask.id] && app.developSelectedMaskId == mask.id,
               "a new mask is saved and selected")
        app.developMasking = true
        app.developMaskCreation = .linear
        _ = app.handleKey("escape", hasCommand: false)
        assert(app.developMasking && app.developMaskCreation == nil, "Esc first disarms a gradient")
        app.developShowsOriginal = true
        _ = app.handleKey("delete", hasCommand: false)
        assert(app.developSettings["x"]?.masks.count == 1, "with the before view up, Delete removes nothing it doesn't show")
        app.developShowsOriginal = false
        undo.beginUndoGrouping()
        _ = app.handleKey("delete", hasCommand: false)
        undo.endUndoGrouping()
        assert(app.developSettings["x"]?.masks.isEmpty == true && app.view == .develop, "Delete removes the selected mask")

        undo.undo()
        assert(app.developSettings["x"]?.masks.count == 1, "undo brings the mask back")
        _ = app.handleKey("escape", hasCommand: false)
        assert(!app.developMasking && app.view == .develop, "Esc closes the masking tool")
        app.developMasking = true
        app.developCropping = true
        assert(!app.developMasking, "the crop tool closes the masking tool")
        app.developMasking = true
        assert(!app.developCropping, "the masking tool closes the crop tool")
        _ = app.handleKey("]", hasCommand: false)
        assert(app.developBrush.size == 30, "] enlarges the brush in the masking tool")
        for _ in 0..<30 { _ = app.handleKey("[", hasCommand: false) }
        assert(app.developBrush.size == 1, "[ shrinks the brush, down to its smallest")
        _ = app.handleKey("o", hasCommand: false)
        assert(app.developShowsMaskOverlay, "O shows the mask overlay")
        app.view = .grid
        assert(!app.developMasking, "leaving Develop closes the masking tool")
        assert(!app.handleKey("[", hasCommand: false), "[ does nothing outside the masking tool")

        // range masks: a color range starts by sampling; clicks add colors, the oldest making way
        let beforeRanges = app.developSettings["x"]
        app.view = .develop
        app.developMasking = true
        undo.beginUndoGrouping()
        var ranged = LocalAdjustment(kind: .radial)
        ranged.exposure = 1
        app.commitDevelop(["x": { var e = DevelopSettings(); e.masks = [ranged]; return e }()], undoName: "radial")
        app.developSelectedMaskId = ranged.id
        app.setMaskRange(.color, maskId: ranged.id, assetId: "x")
        assert(app.developSettings["x"]?.masks.first?.range?.kind == .color && app.developPickingRangeColor,
               "narrowing to a color range starts sampling")
        for i in 0..<6 { app.addRangeSample(CGPoint(x: 0.1 * Double(i), y: 0.5), maskId: ranged.id, assetId: "x") }
        let samples = app.developSettings["x"]?.masks.first?.range?.samples ?? []
        assert(samples.count == MaskRange.maxSamples && samples.first?.x == 0.1, "samples stop at five, the oldest going")
        _ = app.handleKey("escape", hasCommand: false)
        assert(!app.developPickingRangeColor && app.developMasking, "Esc ends sampling first")
        app.setMaskRange(nil, maskId: ranged.id, assetId: "x")
        assert(app.developSettings["x"]?.masks.first?.range == nil, "a range can be taken off again")
        undo.endUndoGrouping()
        app.developSettings["x"] = beforeRanges
        app.view = .grid

        // spot tool: exclusive with the other tools; Delete removes the selected spot, not the photo
        app.view = .develop
        var withSpot = app.developSettings["x"] ?? .neutral
        let spot = SpotRemoval(target: CGPoint(x: 0.3, y: 0.3), source: CGPoint(x: 0.4, y: 0.3), radius: 0.02)
        withSpot.spots = [spot]
        undo.beginUndoGrouping()
        app.commitDevelop(["x": withSpot], undoName: "spot")
        undo.endUndoGrouping()
        app.developMasking = true
        app.developSpotting = true
        assert(!app.developMasking && app.developSpotting, "the spot tool closes the masking tool")
        app.developSelectedSpotId = spot.id
        _ = app.handleKey("]", hasCommand: false)
        assert(app.developSpotBrush.size == 14, "] enlarges the spot brush")
        undo.beginUndoGrouping()
        _ = app.handleKey("delete", hasCommand: false)
        undo.endUndoGrouping()
        assert(app.developSettings["x"]?.spots.isEmpty == true && app.view == .develop, "Delete removes the selected spot")
        undo.undo()
        assert(app.developSettings["x"]?.spots.count == 1, "undo brings the spot back")
        app.developVisualizeSpots = true
        _ = app.handleKey("escape", hasCommand: false)
        assert(!app.developSpotting && !app.developVisualizeSpots && app.view == .develop,
               "Esc closes the spot tool and its dust view")
        app.developSpotting = true
        app.developCropping = true
        assert(!app.developSpotting, "the crop tool closes the spot tool")
        app.view = .grid

        // background work (a spot's source found, auto tone measured) saves its change and keeps
        // a drag in progress, adding the change to it; a commit for another photo leaves it alone
        var dragging = DevelopSettings()
        dragging.exposure = 1
        app.updateDevelopDraft(dragging, for: "d")
        app.commitDevelop(["other": DevelopSettings()], undoName: "other")
        assert(app.developDraft?.assetId == "d", "saving another photo keeps the drag")
        undo.beginUndoGrouping()
        app.commitDevelopChange(["d"], undoName: "spot") { _, settings in
            settings.spots.append(SpotRemoval(target: CGPoint(x: 0.4, y: 0.4), source: CGPoint(x: 0.5, y: 0.4), radius: 0.01))
        }
        undo.endUndoGrouping()
        assert(app.developSettings["d"]?.spots.count == 1 && app.developSettings["d"]?.exposure == 0
               && app.developDraft?.settings.spots.count == 1 && app.developDraft?.settings.exposure == 1,
               "a background change is saved and reaches the drag in progress")
        app.developDraft = nil

        // history: each edit adds a step, undo takes it away, redo puts it back; returning to a
        // step is itself a step
        assert(app.developHistory(for: "h").isEmpty, "a new photo has no history")
        var first = DevelopSettings(); first.exposure = 0.4
        var second = first; second.contrast = 30
        for (value, name) in [(first, "调整曝光度"), (second, "调整对比度")] {
            undo.beginUndoGrouping()
            app.commitDevelop(["h": value], undoName: name)
            undo.endUndoGrouping()
        }
        assert(app.developHistory(for: "h").map(\.name) == ["调整曝光度", "调整对比度"], "each edit adds a history step")
        undo.undo()
        assert(app.developHistory(for: "h").map(\.name) == ["调整曝光度"] && app.developSettings["h"] == first,
               "undo takes the step away")
        undo.redo()
        assert(app.developHistory(for: "h").count == 2 && app.developSettings["h"] == second, "redo puts it back")
        undo.beginUndoGrouping()
        app.applyDevelopHistoryStep(app.developHistory(for: "h")[0], to: "h")
        undo.endUndoGrouping()
        assert(app.developSettings["h"] == first && app.developHistory(for: "h").count == 3,
               "returning to a step restores it as a new step")
        undo.beginUndoGrouping()
        app.applyDevelopHistoryStep(app.developHistory(for: "h")[1], to: "h")
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        app.applyDevelopHistoryStep(app.developHistory(for: "h")[2], to: "h")
        undo.endUndoGrouping()
        let names = app.developHistory(for: "h").map(\.name)
        assert(names.last == L("历史记录：\("调整曝光度")") && !names.contains { $0.hasPrefix(L("历史记录：") + L("历史记录：")) },
               "returning to a history step doesn't nest its name")

        // snapshots keep a state to come back to
        app.createDevelopSnapshot(for: "h")
        let kept = app.developSnapshots(for: "h")
        assert(kept.count == 1 && kept[0].settings == first, "a snapshot keeps the current settings")
        app.renameDevelopSnapshot(kept[0].id, to: "  Soft  ", for: "h")
        undo.beginUndoGrouping()
        app.commitDevelop(["h": second], undoName: "调整对比度")
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        app.applyDevelopSnapshot(app.developSnapshots(for: "h")[0], to: "h")
        undo.endUndoGrouping()
        assert(app.developSettings["h"] == first && app.developSnapshots(for: "h")[0].name == "Soft",
               "applying a snapshot restores its settings; names are trimmed")
        undo.beginUndoGrouping()
        app.commitDevelop(["h": second], undoName: "调整对比度")
        undo.endUndoGrouping()
        app.updateDevelopSnapshot(kept[0].id, for: "h")
        let updated = app.developSnapshots(for: "h")
        assert(updated.count == 1 && updated[0].id == kept[0].id && updated[0].name == "Soft" && updated[0].settings == second,
               "updating a snapshot replaces its settings without changing its identity or name")
        app.deleteDevelopSnapshot(kept[0].id, for: "h")
        assert(app.developSnapshots(for: "h").isEmpty, "snapshots delete")
        app.clearDevelopHistory(for: "h")
        assert(app.developHistory(for: "h").isEmpty && app.developSettings["h"] == second,
               "clearing history keeps the current settings")
    }
}
