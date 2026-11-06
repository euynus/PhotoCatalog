import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

extension PipelineCheck.Run {
    /// 14. managed import copies originals into Originals/
    func managedImport() {
        if let mstore = try? CatalogStore(packageURL: tmp.appendingPathComponent("Managed.photolibrary")) {
            let massets = ImportCoordinator(store: mstore).importFolder(src, mode: .managed)
            let managed = !massets.isEmpty && massets.allSatisfy {
                ($0.localPath?.contains("/Originals/") ?? false) && fm.fileExists(atPath: $0.localPath ?? "")
            }
            check(managed, "managed import copied \(massets.count) originals into Originals/")
        } else { check(false, "managed catalog") }
    }

    /// 15. batch rename moves the original on disk
    func batchRename() {
        let ren = assets[2]
        if let renURL = RenameService.renameWithTemplate([ren], template: "RENAMED_{seq}")[ren.id] {
            check(fm.fileExists(atPath: renURL.path) && renURL.lastPathComponent.hasPrefix("RENAMED_"),
                  "batch rename moved original to \(renURL.lastPathComponent)")
        } else { check(false, "batch rename") }
    }

    /// 17. relocated-original matching from a user-selected folder
    func relocation() {
        if let sample = assets.first, let path = sample.localPath {
            let relocated = tmp.appendingPathComponent("relocated")
            try? fm.createDirectory(at: relocated, withIntermediateDirectories: true)
            let copy = relocated.appendingPathComponent(sample.filename)
            try? fm.copyItem(at: URL(fileURLWithPath: path), to: copy)
            let found = RelocationService.replacement(for: sample, selected: relocated)
            let foundPath = found?.standardizedFileURL.path
            let copyPath = copy.standardizedFileURL.path
            check(foundPath == copyPath,
                  "relocation matched moved original by folder selection - found \(found?.path ?? "nil"), expected \(copy.path)")
        } else { check(false, "relocation sample asset") }
    }

    /// 18. background availability resolution + narrow persistence
    func availability() {
        var unavailable = (try? store.loadAssets())?.first { $0.id == assets[0].id } ?? assets[0]
        unavailable.status = .ready
        unavailable.localPath = tmp.appendingPathComponent("gone.jpg").path
        let availabilityChanges = AssetAvailabilityService.changes(
            in: [unavailable],
            sourceRootsById: [:]
        )
        check(availabilityChanges == [
            AssetAvailabilityUpdate(
                assetId: unavailable.id,
                status: .missing,
                localPath: unavailable.localPath
            )
        ], "availability scan reports a missing internal original")

        let originalTitle = unavailable.title
        try? store.updateAssetAvailability(availabilityChanges ?? [])
        let availabilitySaved = (try? store.loadAssets())?.first { $0.id == unavailable.id }
        check(availabilitySaved?.status == .missing
              && availabilitySaved?.localPath == unavailable.localPath
              && availabilitySaved?.title == originalTitle,
              "availability persistence changes only status and path")
    }

    /// 19. offline external-volume classification (§6.4 ORG-007)
    func externalVolumes() {
        check(VolumeMonitor.volumeRoot(of: "/Volumes/Photos/2026/a.jpg") == "/Volumes/Photos",
              "external volume root extracted")
        check(VolumeMonitor.volumeRoot(of: "/Users/me/Pictures/a.jpg") == nil, "internal path has no volume root")
        check(VolumeMonitor.pathByReplacingVolumeRoot(
            in: "/Volumes/OldName/Photos/2026/a.jpg",
            oldRoot: "/Volumes/OldName",
            newRoot: "/Volumes/NewName"
        ) == "/Volumes/NewName/Photos/2026/a.jpg", "external volume root replacement")
        check(VolumeMonitor.volumeIdentifier(for: tmp)?.isEmpty == false, "filesystem volume identifier read")
        check(VolumeMonitor.status(forInaccessible: "/Volumes/NoSuchDrive_\(UUID().uuidString)/x.jpg") == .offline,
              "unmounted volume → offline")
        check(VolumeMonitor.status(forInaccessible: "/Users/me/gone_\(UUID().uuidString).jpg") == .missing,
              "internal gone → missing")
    }
}
