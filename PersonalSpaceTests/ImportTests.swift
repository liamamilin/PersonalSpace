import CryptoKit
import GRDB
import XCTest
@testable import PersonalSpace

@MainActor
final class ImportTests: XCTestCase {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func folder(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func testImportCopiesOriginalAndRemainsSearchableAfterReopeningAndMovingOriginal() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try folder("收纳来源_%", in: root)
        let original = source.appendingPathComponent("采购凭证.txt")
        let bytes = Data("synthetic import only\n正文不自动索引\n".utf8)
        try bytes.write(to: original)
        let originalDate = try original.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let path = root.appendingPathComponent("library.sqlite").path
        let database = try LibraryDatabase(path: path)
        let store = ManagedFileStore(root: root.appendingPathComponent("Vault"))

        let id = try await store.importFile(sourceURL: original, database: database)
        let saved = try await database.file(id: id)
        let file = try XCTUnwrap(saved)
        let copyPath = try XCTUnwrap(file.managedCopyPath)
        XCTAssertTrue(file.isImported)
        XCTAssertFalse(file.isPhoto)
        XCTAssertFalse(file.isAvailable, "The original has no persistent access grant")
        XCTAssertEqual(file.name, original.lastPathComponent)
        XCTAssertEqual(file.bytes, Int64(bytes.count))
        XCTAssertEqual(file.managedSHA256, digest(bytes))
        XCTAssertNotNil(file.managedAt)
        XCTAssertNil(file.textIndexedAt)
        XCTAssertEqual(file.importedFromPath, original.path)
        XCTAssertEqual(file.fullPath, original.path)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertEqual(try original.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, originalDate)
        XCTAssertEqual(try Data(contentsOf: store.url(for: copyPath)), bytes)
        try FileManager.default.moveItem(at: original, to: root.appendingPathComponent("moved-test-original.txt"))

        let reopened = try LibraryDatabase(path: path)
        let byName = try await reopened.files(FileQuery(search: "采购", inboxOnly: true))
        let byPath = try await reopened.files(FileQuery(search: "收纳来源_%"))
        let managed = try await reopened.files(FileQuery(managedOnly: true))
        let text = try await reopened.documentText(itemID: id)
        XCTAssertEqual(byName.files.map(\.id), [id])
        XCTAssertEqual(byPath.files.map(\.id), [id])
        XCTAssertEqual(managed.files.map(\.id), [id])
        XCTAssertNil(text)
        XCTAssertEqual(try Data(contentsOf: store.url(for: copyPath)), bytes)
    }

    func testSameNamesAndRepeatedImportsAreIndependentCopies() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try folder("A", in: root), b = try folder("B", in: root)
        let first = a.appendingPathComponent("同名凭证.txt"), second = b.appendingPathComponent("同名凭证.txt")
        let firstBytes = Data("first synthetic file".utf8), secondBytes = Data("second synthetic file".utf8)
        try firstBytes.write(to: first)
        try secondBytes.write(to: second)
        let database = try LibraryDatabase(path: ":memory:")
        let store = ManagedFileStore(root: root.appendingPathComponent("Vault"))
        let firstID = try await store.importFile(sourceURL: first, database: database)
        let secondID = try await store.importFile(sourceURL: second, database: database)
        let thirdID = try await store.importFile(sourceURL: first, database: database)
        let all = try await database.files(FileQuery(inboxOnly: true))
        XCTAssertEqual(Set(all.files.map(\.id)), [firstID, secondID, thirdID])
        XCTAssertEqual(Set(all.files.compactMap(\.managedCopyPath)).count, 3)
        for file in all.files {
            let expected = file.id == secondID ? secondBytes : firstBytes
            XCTAssertEqual(try Data(contentsOf: store.url(for: XCTUnwrap(file.managedCopyPath))), expected)
        }
        XCTAssertEqual(try Data(contentsOf: first), firstBytes)
        XCTAssertEqual(try Data(contentsOf: second), secondBytes)
    }

    func testObjectAndFourMatterKindsOrganizeInboxWithoutRemovingImportedFile() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("事务凭证.txt")
        try Data("synthetic shared receipt".utf8).write(to: original)
        let path = root.appendingPathComponent("library.sqlite").path
        let database = try LibraryDatabase(path: path)
        let store = ManagedFileStore(root: root.appendingPathComponent("Vault"))
        let id = try await store.importFile(sourceURL: original, database: database)
        try await database.saveObject(id: "computer", name: "我的电脑", kind: "device", notes: "")
        try await database.linkItems([id], to: "computer")
        let afterObject = try await database.files(FileQuery(inboxOnly: true, limit: 0))
        XCTAssertEqual(afterObject.total, 0)
        let kinds = ["order", "contract", "warranty", "subscription"]
        for kind in kinds {
            try await database.saveMatter(MatterDraft(id: kind, kind: kind, title: kind, itemIDs: [id]))
        }

        let reopened = try LibraryDatabase(path: path)
        let objectFiles = try await reopened.files(FileQuery(objectID: "computer"))
        XCTAssertEqual(objectFiles.files.map(\.id), [id])
        try await reopened.unlinkItem(id, from: "computer")
        let stillInMatters = try await reopened.files(FileQuery(inboxOnly: true))
        XCTAssertEqual(stillInMatters.total, 0)
        for kind in kinds {
            let linked = try await reopened.files(FileQuery(matterID: kind))
            XCTAssertEqual(linked.files.map(\.id), [id])
            try await reopened.saveMatter(MatterDraft(id: kind, kind: kind, title: kind, itemIDs: []))
        }
        let unorganizedAgain = try await reopened.files(FileQuery(inboxOnly: true))
        let all = try await reopened.files(FileQuery())
        XCTAssertEqual(unorganizedAgain.files.map(\.id), [id])
        XCTAssertEqual(all.files.map(\.id), [id])
    }

    func testImportSourceIsNeverScannedAndSensitiveImportDoesNotIndexBody() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("合成账号密码.txt")
        try Data("synthetic-unique-body-for-test".utf8).write(to: original)
        let database = try LibraryDatabase(path: ":memory:")
        let store = ManagedFileStore(root: root.appendingPathComponent("Vault"))
        let id = try await store.importFile(sourceURL: original, database: database)
        let sources = try await database.sources()
        let folderSource = try await database.findSource(path: "inbox://imports")
        let file = try await database.file(id: id)
        let bodyResults = try await database.files(FileQuery(search: "synthetic-unique-body-for-test", searchBody: true))
        let sourceMetadata = try await database.queue.read { db -> (String?, Data?) in
            let row = try Row.fetchOne(db, sql: "SELECT kind, bookmark FROM source WHERE id='inbox'")
            return (row?["kind"], row?["bookmark"])
        }
        XCTAssertTrue(sources.isEmpty)
        XCTAssertNil(folderSource)
        XCTAssertEqual(file?.sensitivity, "suspected")
        XCTAssertEqual(bodyResults.total, 0)
        XCTAssertEqual(sourceMetadata.0, "import")
        XCTAssertEqual(sourceMetadata.1, Data())
        XCTAssertThrowsError(try database.saveBatch([], sourceID: "inbox", scanID: "forbidden"))
        XCTAssertThrowsError(try database.finishScan(sourceID: "inbox", scanID: "forbidden"))
        do {
            try await database.saveDocumentText(itemID: id, text: "synthetic-unique-body-for-test")
            XCTFail("Sensitive import unexpectedly accepted a body index")
        } catch { }
        do {
            try await database.saveSource(id: "inbox", name: "invalid", path: root.path, bookmark: Data([1]))
            XCTFail("Reserved import source became a folder")
        } catch { }
    }

    func testRejectedInputsLeaveNoRecordsOrPartialCopies() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try folder("ordinary-folder", in: root)
        let package = try folder("Synthetic.app", in: root)
        let original = root.appendingPathComponent("original.txt")
        let bytes = Data("unchanged synthetic original".utf8)
        try bytes.write(to: original)
        let symlink = root.appendingPathComponent("linked.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: original)
        let database = try LibraryDatabase(path: ":memory:")
        let vault = root.appendingPathComponent("Vault")
        let store = ManagedFileStore(root: vault)
        for invalid in [directory, package, symlink, root.appendingPathComponent("missing.txt"),
                        URL(string: "https://example.invalid/file.txt")!] {
            do {
                _ = try await store.importFile(sourceURL: invalid, database: database)
                XCTFail("Invalid input unexpectedly imported: \(invalid.lastPathComponent)")
            } catch { }
        }
        let all = try await database.files(FileQuery())
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: vault.path)) ?? []
        XCTAssertEqual(all.total, 0)
        XCTAssertTrue(leftovers.isEmpty)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }

    func testDatabaseFailureRollsBackSourceAndDiscardsOnlyNewCopy() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("合成凭证.txt")
        let bytes = Data("synthetic original survives failure".utf8)
        try bytes.write(to: original)
        let database = try LibraryDatabase(path: ":memory:")
        let vault = root.appendingPathComponent("Vault")
        let store = ManagedFileStore(root: vault)
        let retained = try store.copy(sourceURL: original)
        try await database.queue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_import BEFORE INSERT ON item WHEN new.kind='imported'
                BEGIN SELECT RAISE(ABORT, 'synthetic rejected import'); END;
                """)
        }
        do {
            _ = try await store.importFile(sourceURL: original, database: database)
            XCTFail("Rejected database write unexpectedly succeeded")
        } catch { }
        let all = try await database.files(FileQuery())
        let importSourceCount = try await database.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM source WHERE id='inbox'")
        }
        XCTAssertEqual(all.total, 0)
        XCTAssertEqual(importSourceCount, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vault.path),
                       [String(retained.relativePath.split(separator: "/")[0])])
        XCTAssertEqual(try Data(contentsOf: store.url(for: retained.relativePath)), bytes)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }

    func testM6SchemaUpgradeRetainsExistingFileObjectAndBodySearch() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("library.sqlite").path
        let initial = try LibraryDatabase(path: path)
        try await initial.saveSource(id: "folder", name: "旧来源", path: "/synthetic/m6", bookmark: Data([1]))
        try initial.saveBatch([ScannedFile(relativePath: "旧凭证.txt", name: "旧凭证.txt",
            typeIdentifier: "public.plain-text", bytes: 12)], sourceID: "folder", scanID: "old")
        let oldFiles = try await initial.files(FileQuery())
        let id = try XCTUnwrap(oldFiles.files.first?.id)
        try await initial.saveObject(id: "object", name: "旧对象", kind: "other", notes: "")
        try await initial.linkItems([id], to: "object")
        try await initial.saveDocumentText(itemID: id, text: "existingsearchabletext")
        // Remove only the M7 addition to recreate the released M6 table shape and migration list.
        try await initial.queue.write { db in
            try db.execute(sql: "ALTER TABLE item DROP COLUMN importedFromPath")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='M7-quick-imports'")
        }
        let upgraded = try LibraryDatabase(path: path)
        let old = try await upgraded.file(id: id)
        let linked = try await upgraded.files(FileQuery(objectID: "object"))
        let body = try await upgraded.files(FileQuery(search: "existingsearchabletext", searchBody: true))
        let inbox = try await upgraded.files(FileQuery(inboxOnly: true))
        XCTAssertEqual(old?.itemKind, "file")
        XCTAssertNil(old?.importedFromPath)
        XCTAssertEqual(old?.sourceID, "folder")
        XCTAssertEqual(linked.files.map(\.id), [id])
        XCTAssertEqual(body.files.map(\.id), [id])
        XCTAssertEqual(inbox.total, 0)
    }
}
