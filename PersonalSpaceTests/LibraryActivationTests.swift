import GRDB
import XCTest
@testable import PersonalSpace

@MainActor
final class LibraryActivationTests: XCTestCase {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testRestoreActivateEditImportExportAndReturnToOriginalLibrary() async throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let selection = ActiveLibrary(base: base)
        let original = try selection.current()
        let database = try LibraryDatabase(path: original.databaseURL.path)
        let external = base.appendingPathComponent("External")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        let receipt = external.appendingPathComponent("合成订单.txt")
        let bytes = Data("Synthetic M10 receipt; no personal data.".utf8)
        try bytes.write(to: receipt)
        try await database.saveSource(id: "source", name: "来源", path: external.path, bookmark: FolderAccess.bookmark(for: external))
        try FolderScanner.scan(root: external, sourceID: "source", database: database)
        let initial = try await database.files(FileQuery())
        let item = try XCTUnwrap(initial.files.first)
        let store = ManagedFileStore(root: original.vault)
        let copy = try store.copy(sourceURL: receipt)
        try await database.saveManagedCopy(itemID: item.id, relativePath: copy.relativePath, sha256: copy.sha256)
        try await database.saveObject(id: "computer", name: "我的电脑", kind: "device", notes: "合成恢复测试")
        try await database.linkItems([item.id], to: "computer")
        for kind in ["order", "contract", "warranty", "subscription"] {
            try await database.saveMatter(MatterDraft(id: kind, kind: kind, title: "合成 \(kind)", objectID: "computer", itemIDs: [item.id],
                facts: [FactDraft(id: "fact-" + kind, key: "end_date", valueText: "2030-12-31", valueType: "date", state: "confirmed", sourceItemID: item.id)],
                actions: [ActionDraft(id: "a-" + kind, title: "行动 A", remindAt: Date(timeIntervalSince1970: 1_900_000_000), state: "active", dateConfirmed: true),
                          ActionDraft(id: "b-" + kind, title: "行动 B")]))
        }
        try await database.savePhotos([ScannedPhoto(localIdentifier: "synthetic-m10-photo", name: "合成照片")])
        let photos = try await database.files(FileQuery(sourceID: "photos"))
        try await database.linkItems(photos.files.map(\.id), to: "computer")
        let backup = base.appendingPathComponent("Backup")
        _ = try await LibraryBackup.export(database: database, vaultRoot: original.vault, to: backup)
        let summary = try await LibraryBackup.inspect(at: backup)
        XCTAssertEqual(summary.itemCount, 2)
        XCTAssertEqual(summary.matterCount, 4)
        XCTAssertEqual(summary.managedCount, 1)
        _ = try await store.importFile(sourceURL: receipt, database: database)

        let restoredLocation = try selection.newRestoreLocation()
        _ = try await LibraryBackup.restore(from: backup, to: restoredLocation.root)
        let restored = try LibraryDatabase(path: restoredLocation.databaseURL.path)
        try await restored.prepareRestoredLibrary()
        try await selectionSchedule(selection, target: restoredLocation, current: original)
        XCTAssertEqual(try ActiveLibrary(base: base).current(), restoredLocation)
        XCTAssertEqual(try selection.selection().previous, "original")
        let sources = try await restored.sources()
        let source = try XCTUnwrap(sources.first)
        XCTAssertEqual(source.id, "source")
        XCTAssertTrue(source.needsAuthorization)
        XCTAssertTrue(source.bookmark.isEmpty)
        XCTAssertThrowsError(try FolderAccess.resolve(source))
        let restoredFiles = try await restored.files(FileQuery())
        XCTAssertEqual(restoredFiles.files.map(\.id), [item.id])
        XCTAssertEqual(restoredFiles.files.first?.isAvailable, false)
        XCTAssertEqual(try Data(contentsOf: ManagedFileStore(root: restoredLocation.vault).url(for: copy.relativePath)), bytes)
        let objects = try await restored.objects()
        let matters = try await restored.matters()
        XCTAssertEqual(objects.first?.itemCount, 2)
        XCTAssertEqual(Set(matters.map(\.kind)), ["order", "contract", "warranty", "subscription"])
        let restoredLinks = try await restored.files(FileQuery(objectID: "computer"))
        XCTAssertEqual(Set(restoredLinks.files.map(\.itemKind)), ["file", "photo"])
        XCTAssertTrue(restoredLinks.files.allSatisfy { !$0.isAvailable })

        let aBefore = try await restored.action(id: "a-warranty")
        let facts = try await restored.facts(matterID: "warranty")
        var edited = MatterDraft(id: "warranty", kind: "warranty", title: "恢复后修改", objectID: "computer", itemIDs: [item.id],
            facts: facts.map { FactDraft(id: $0.id, key: $0.key, valueText: "2031-12-31", valueType: $0.valueType, state: $0.state, sourceItemID: $0.sourceItemID) })
        edited.actions = [ActionDraft(id: "new", title: "恢复后新增行动")]
        try await restored.saveMatter(edited)
        let retainedA = try await restored.action(id: "a-warranty")
        XCTAssertEqual(retainedA.map(ActionDraft.init), aBefore.map(ActionDraft.init))
        XCTAssertEqual(retainedA?.updatedAt, aBefore?.updatedAt)
        XCTAssertEqual(retainedA?.matterTitle, "恢复后修改")
        let bRecord = try await restored.action(id: "b-warranty")
        var b = ActionDraft(try XCTUnwrap(bRecord))
        b.title = "单独修改 B"
        b.state = "done"
        _ = try await restored.saveAction(b, matterID: "warranty")
        let changedB = try await restored.action(id: "b-warranty")
        XCTAssertEqual(changedB?.state, "done")
        let restoredStore = ManagedFileStore(root: restoredLocation.vault)
        _ = try await restoredStore.importFile(sourceURL: receipt, database: restored)
        let secondBackup = base.appendingPathComponent("SecondBackup")
        _ = try await LibraryBackup.export(database: restored, vaultRoot: restoredLocation.vault, to: secondBackup)
        _ = try await LibraryBackup.verify(at: secondBackup)
        try await selectionSchedule(selection, target: original, current: restoredLocation)
        XCTAssertEqual(try selection.current(), original)
        XCTAssertEqual(try selection.selection().previous, restoredLocation.id)
        let originalItems = try await database.files(FileQuery())
        XCTAssertEqual(originalItems.total, 3)
        XCTAssertEqual(try Data(contentsOf: receipt), bytes)
    }

    private func selectionSchedule(_ selection: ActiveLibrary, target: LibraryLocation, current: LibraryLocation) async throws {
        try await Task.detached { try selection.scheduleSwitch(to: target, from: current) }.value
    }

    func testReauthorizationAtDifferentPathKeepsItemObjectAndMatterIDs() async throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let database = try LibraryDatabase(path: base.appendingPathComponent("library.sqlite").path)
        try await database.saveSource(id: "source", name: "旧位置", path: "/old-device/synthetic", bookmark: Data([1]))
        try database.saveBatch([ScannedFile(relativePath: "凭证.txt", name: "凭证.txt", typeIdentifier: "public.text", bytes: 3)], sourceID: "source", scanID: "old")
        let oldFiles = try await database.files(FileQuery())
        let item = try XCTUnwrap(oldFiles.files.first)
        try await database.saveObject(id: "object", name: "我的电脑", kind: "device", notes: "")
        try await database.linkItems([item.id], to: "object")
        try await database.saveMatter(MatterDraft(id: "matter", title: "合成订单", itemIDs: [item.id]))
        try await database.prepareRestoredLibrary()
        let model = LibraryModel(database: database)
        model.selectedMatterID = "matter"
        await model.reload()
        XCTAssertEqual(model.matterFiles.first?.isAvailable, false)
        let newFolder = base.appendingPathComponent("NewLocation")
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: false)
        try Data("new".utf8).write(to: newFolder.appendingPathComponent("凭证.txt"))
        try await database.reauthorizeSource(id: "source", name: "新位置", path: newFolder.path, bookmark: FolderAccess.bookmark(for: newFolder))
        let sources = try await database.sources()
        let source = try XCTUnwrap(sources.first)
        XCTAssertEqual(source.id, "source")
        XCTAssertFalse(source.needsAuthorization)
        let access = try FolderAccess.resolve(source)
        defer { access.url.stopAccessingSecurityScopedResource() }
        try FolderScanner.scan(root: access.url, sourceID: source.id, database: database)
        await model.reload()
        XCTAssertEqual(model.matterFiles.first?.id, item.id)
        XCTAssertEqual(model.matterFiles.first?.isAvailable, true)
        let linked = try await database.files(FileQuery(objectID: "object"))
        let evidence = try await database.files(FileQuery(matterID: "matter"))
        XCTAssertEqual(linked.files.first?.id, item.id)
        XCTAssertEqual(evidence.files.first?.id, item.id)
        XCTAssertEqual(linked.files.first?.isAvailable, true)
        XCTAssertEqual(linked.files.first?.sourcePath, newFolder.path)
    }

    func testInvalidTargetNeverChangesPointerAndMissingActiveDatabaseIsNotRecreated() async throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let selection = ActiveLibrary(base: base)
        let original = try selection.current()
        _ = try LibraryDatabase(path: original.databaseURL.path)
        let missing = try selection.newRestoreLocation()
        XCTAssertThrowsError(try selection.scheduleSwitch(to: missing, from: original))
        XCTAssertEqual(try selection.current(), original)
        let file = base.appendingPathComponent("active-library.json")
        try JSONEncoder().encode(ActiveLibrary.Selection(active: missing.id, previous: "original")).write(to: file)
        XCTAssertThrowsError(try selection.current())
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.databaseURL.path))
        try Data("{\"active\":\"../../outside\"}".utf8).write(to: file)
        XCTAssertThrowsError(try selection.selection())
    }

    func testReminderRequestsAreScopedWithoutChangingLegacyIdentifiers() async throws {
        XCTAssertEqual(ReminderController.identifier(for: "a"), "action.a")
        XCTAssertNotEqual(ReminderController.identifier(for: "a", libraryID: "one"), ReminderController.identifier(for: "a", libraryID: "two"))
        let restored = ReminderController(libraryID: UUID().uuidString)
        let actualRequests = await restored.pendingReminders()
        XCTAssertTrue(actualRequests.isEmpty, "Fresh restored library must not claim another library's requests")
    }
}
