import GRDB
import XCTest
@testable import PersonalSpace

@MainActor
final class ImportedRemovalTests: XCTestCase {
    private func fixture() async throws -> (root: URL, original: URL, database: LibraryDatabase, store: ManagedFileStore, id: String, copy: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("合成移除测试.txt")
        try Data("synthetic removable receipt\n".utf8).write(to: original)
        let database = try LibraryDatabase(path: root.appendingPathComponent("Library.sqlite").path)
        let store = ManagedFileStore(root: root.appendingPathComponent("Vault"))
        let id = try await store.importFile(sourceURL: original, database: database)
        let saved = try await database.file(id: id)
        let file = try XCTUnwrap(saved)
        return (root, original, database, store, id, try store.url(for: XCTUnwrap(file.managedCopyPath)))
    }

    func testRemovalDeletesRecordCopyAndBodyIndexButPreservesOriginalAfterReopen() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let bytes = try Data(contentsOf: f.original)
        let date = try f.original.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try await f.database.saveDocumentText(itemID: f.id, text: "unique-removal-body")
        try await f.store.removeImportedFile(itemID: f.id, database: f.database)
        let reopened = try LibraryDatabase(path: f.root.appendingPathComponent("Library.sqlite").path)
        for query in [FileQuery(), FileQuery(managedOnly: true), FileQuery(inboxOnly: true),
                      FileQuery(search: "unique-removal-body", searchBody: true)] {
            let result = try await reopened.files(query)
            XCTAssertEqual(result.total, 0)
        }
        let body = try await reopened.documentText(itemID: f.id)
        XCTAssertNil(body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.copy.path))
        XCTAssertEqual(try Data(contentsOf: f.original), bytes)
        XCTAssertEqual(try f.original.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date)
    }

    func testObjectMatterAndFactReferencesBlockRemovalUntilUnlinked() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.database.saveObject(id: "computer", name: "合成电脑", kind: "device", notes: "")
        try await f.database.linkItems([f.id], to: "computer")
        do { try await f.store.removeImportedFile(itemID: f.id, database: f.database); XCTFail("Linked object must block") }
        catch { XCTAssertTrue(error.localizedDescription.contains("解除")) }
        try await f.database.unlinkItem(f.id, from: "computer")
        var matter = MatterDraft(id: "matter", title: "合成事务", itemIDs: [f.id])
        try await f.database.saveMatter(matter)
        do { try await f.store.removeImportedFile(itemID: f.id, database: f.database); XCTFail("Matter must block") }
        catch { XCTAssertTrue(error.localizedDescription.contains("解除")) }
        matter.itemIDs = []
        matter.facts = [FactDraft(key: "product", valueText: "合成设备", sourceItemID: f.id)]
        try await f.database.saveMatter(matter)
        do { try await f.store.removeImportedFile(itemID: f.id, database: f.database); XCTFail("Citation must block") }
        catch { XCTAssertTrue(error.localizedDescription.contains("解除")) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.copy.path))
        let retained = try await f.database.file(id: f.id)
        XCTAssertNotNil(retained)
        matter.facts = []
        try await f.database.saveMatter(matter)
        try await f.store.removeImportedFile(itemID: f.id, database: f.database)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.copy.path))
    }

    func testDatabaseFailureAndNonImportedRecordNeverDeleteCopy() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.database.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_removal BEFORE DELETE ON item BEGIN SELECT RAISE(ABORT, 'synthetic refusal'); END")
        }
        do { try await f.store.removeImportedFile(itemID: f.id, database: f.database); XCTFail("Write must fail") }
        catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.copy.path))
        let retained = try await f.database.file(id: f.id)
        XCTAssertNotNil(retained)
        try await f.database.queue.write { db in
            try db.execute(sql: "DROP TRIGGER reject_removal")
            try db.execute(sql: "UPDATE item SET kind='file' WHERE id=?", arguments: [f.id])
        }
        do { try await f.store.removeImportedFile(itemID: f.id, database: f.database); XCTFail("Ordinary source cannot be removed") }
        catch { XCTAssertTrue(error.localizedDescription.contains("快速收纳")) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.copy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.original.path))
    }

    func testFileCleanupFailureIsExplicitAndNeverLeavesDanglingRecordOrDeletesSymlinkTarget() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let bytes = try Data(contentsOf: f.original)
        let retained = f.root.appendingPathComponent("retained-copy.txt")
        try FileManager.default.moveItem(at: f.copy, to: retained)
        try FileManager.default.createSymbolicLink(at: f.copy, withDestinationURL: f.original)
        var pending: String?
        do { try await f.store.removeImportedFile(itemID: f.id, database: f.database); XCTFail("Symlink must not be unlinked as a copy") }
        catch let error as ImportedRemovalError {
            if case .copyCleanupPending(let path) = error { pending = path }
            XCTAssertTrue(error.localizedDescription.contains("未能删除"))
        }
        let record = try await f.database.file(id: f.id)
        XCTAssertNil(record)
        XCTAssertEqual(try Data(contentsOf: f.original), bytes)
        try FileManager.default.removeItem(at: f.copy) // remove only this test's symlink
        try FileManager.default.moveItem(at: retained, to: f.copy)
        try f.store.removeCopy(XCTUnwrap(pending))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.copy.path))
        XCTAssertEqual(try Data(contentsOf: f.original), bytes)
    }
}
