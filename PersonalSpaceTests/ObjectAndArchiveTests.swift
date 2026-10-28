import CryptoKit
import GRDB
import XCTest
@testable import PersonalSpace

@MainActor
final class ObjectAndArchiveTests: XCTestCase {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func folder(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func scan(_ folder: URL, id: String, database: LibraryDatabase) async throws {
        try await database.saveSource(id: id, name: folder.lastPathComponent,
                                      path: folder.path, bookmark: Data([1]))
        try FolderScanner.scan(root: folder, sourceID: id, database: database)
    }

    // Keep the released M1 schema here so this exercises a real upgrade, not a fresh M2 database.
    private func createM1Database(path: String) throws {
        let queue = try DatabaseQueue(path: path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("M1-file-library") { db in
            try db.execute(sql: """
                CREATE TABLE source (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    path TEXT NOT NULL UNIQUE,
                    bookmark BLOB NOT NULL,
                    lastScannedAt DATETIME,
                    lastError TEXT
                );
                CREATE TABLE item (
                    id TEXT PRIMARY KEY NOT NULL,
                    sourceID TEXT NOT NULL REFERENCES source(id) ON DELETE CASCADE,
                    relativePath TEXT NOT NULL,
                    name TEXT NOT NULL,
                    typeIdentifier TEXT NOT NULL,
                    bytes INTEGER NOT NULL,
                    modifiedAt DATETIME,
                    createdAt DATETIME,
                    indexedAt DATETIME NOT NULL,
                    scanID TEXT NOT NULL,
                    isAvailable BOOLEAN NOT NULL DEFAULT 1,
                    UNIQUE(sourceID, relativePath)
                );
                CREATE INDEX item_source ON item(sourceID);
                CREATE INDEX item_name ON item(name COLLATE NOCASE);
                """)
        }
        try migrator.migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO source(id, name, path, bookmark)
                VALUES ('legacy-source', '旧来源', '/synthetic/legacy', X'01');
                INSERT INTO item(id, sourceID, relativePath, name, typeIdentifier, bytes, indexedAt, scanID)
                VALUES ('legacy-order', 'legacy-source', '订单.txt', '订单.txt', 'public.plain-text', 10,
                        '2026-10-28 01:00:00', 'legacy-scan'),
                       ('legacy-invoice', 'legacy-source', '发票.txt', '发票.txt', 'public.plain-text', 20,
                        '2026-10-28 01:00:00', 'legacy-scan');
                """)
        }
    }

    func testM1MigrationPreservesBothFilesAndAllowsObjects() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("legacy.sqlite").path
        try createM1Database(path: path)

        let database = try LibraryDatabase(path: path)
        let files = try await database.files(FileQuery())
        let sources = try await database.sources()
        XCTAssertEqual(Set(files.files.map(\.id)), ["legacy-order", "legacy-invoice"])
        XCTAssertEqual(files.files.map(\.bytes).sorted(), [10, 20])
        XCTAssertEqual(sources.first?.id, "legacy-source")
        XCTAssertTrue(files.files.allSatisfy { $0.managedCopyPath == nil && $0.managedSHA256 == nil })

        try await database.saveObject(id: "computer", name: "我的电脑", kind: "device", notes: "升级后创建")
        try await database.linkItems(["legacy-order", "legacy-invoice"], to: "computer")
        let objects = try await database.objects()
        XCTAssertEqual(objects.first?.itemCount, 2)
    }

    func testObjectsKeepCrossSourceAndManyToManyRelationsAfterReopening() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try folder("A", in: root), b = try folder("B", in: root)
        let order = a.appendingPathComponent("订单.txt"), invoice = b.appendingPathComponent("发票.txt")
        try Data("synthetic order".utf8).write(to: order)
        try Data("synthetic invoice".utf8).write(to: invoice)
        let path = root.appendingPathComponent("library.sqlite").path
        let database = try LibraryDatabase(path: path)
        try await scan(a, id: "a", database: database)
        try await scan(b, id: "b", database: database)
        let files = try await database.files(FileQuery())
        let orderID = try XCTUnwrap(files.files.first { $0.name == "订单.txt" }?.id)
        let invoiceID = try XCTUnwrap(files.files.first { $0.name == "发票.txt" }?.id)

        try await database.saveObject(id: "computer", name: "电脑", kind: "device", notes: "原备注")
        try await database.saveObject(id: "receipts", name: "家庭凭证", kind: "other", notes: "")
        try await database.linkItems([orderID, invoiceID], to: "computer")
        try await database.linkItems([orderID], to: "computer")
        try await database.linkItems([orderID], to: "receipts")
        let created = try await database.objects()
        let createdComputer = try XCTUnwrap(created.first { $0.id == "computer" })
        try await database.saveObject(id: "computer", name: "我的电脑", kind: "device", notes: "两份凭证")

        let reopened = try LibraryDatabase(path: path)
        let objects = try await reopened.objects(search: "我的电脑")
        let computer = try XCTUnwrap(objects.first)
        XCTAssertEqual(objects.count, 1)
        XCTAssertEqual(computer.kind, "device")
        XCTAssertEqual(computer.notes, "两份凭证")
        XCTAssertEqual(computer.itemCount, 2)
        XCTAssertEqual(computer.createdAt, createdComputer.createdAt)
        XCTAssertGreaterThanOrEqual(computer.updatedAt, createdComputer.updatedAt)
        let linked = try await reopened.files(FileQuery(objectID: "computer"))
        XCTAssertEqual(Set(linked.files.map(\.sourceID)), ["a", "b"])
        let owners = try await reopened.objectsForItem(orderID)
        XCTAssertEqual(Set(owners.map(\.id)), ["computer", "receipts"])

        try await reopened.unlinkItem(orderID, from: "computer")
        let remaining = try await reopened.files(FileQuery(objectID: "computer"))
        let remainingOwners = try await reopened.objectsForItem(orderID)
        XCTAssertEqual(remaining.files.map(\.id), [invoiceID])
        XCTAssertEqual(remainingOwners.map(\.id), ["receipts"])
        try await reopened.deleteObject("receipts")
        let allFiles = try await reopened.files(FileQuery())
        XCTAssertEqual(allFiles.total, 2)
        XCTAssertEqual(try Data(contentsOf: order), Data("synthetic order".utf8))
        XCTAssertEqual(try Data(contentsOf: invoice), Data("synthetic invoice".utf8))
    }

    func testManagedCopyMatchesHashAndSurvivesMovingOriginal() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try folder("A", in: root)
        let original = a.appendingPathComponent("订单凭证.txt")
        let bytes = Data("synthetic receipt\n金额：100\n".utf8)
        try bytes.write(to: original)
        let path = root.appendingPathComponent("library.sqlite").path
        let database = try LibraryDatabase(path: path)
        try await scan(a, id: "a", database: database)
        let initial = try await database.files(FileQuery())
        let itemID = try XCTUnwrap(initial.files.first?.id)
        let store = ManagedFileStore(root: root.appendingPathComponent("Vault"))

        let copy = try store.copy(sourceURL: original)
        let managedURL = try store.url(for: copy.relativePath)
        XCTAssertEqual(try Data(contentsOf: managedURL), bytes)
        XCTAssertEqual(copy.sha256, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        try await database.saveManagedCopy(itemID: itemID, relativePath: copy.relativePath, sha256: copy.sha256)
        try FileManager.default.moveItem(at: original, to: root.appendingPathComponent("moved-original.txt"))
        try FolderScanner.scan(root: a, sourceID: "a", database: database)

        let reopened = try LibraryDatabase(path: path)
        let savedFile = try await reopened.file(id: itemID)
        let saved = try XCTUnwrap(savedFile)
        XCTAssertFalse(saved.isAvailable)
        XCTAssertEqual(saved.managedCopyPath, copy.relativePath)
        XCTAssertEqual(saved.managedSHA256, copy.sha256)
        XCTAssertNotNil(saved.managedAt)
        XCTAssertEqual(try Data(contentsOf: store.url(for: copy.relativePath)), bytes)
    }

    func testFailedCopyLeavesNoSuccessMetadataOrPartialFiles() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try folder("A", in: root)
        let original = a.appendingPathComponent("订单.txt")
        try Data("synthetic".utf8).write(to: original)
        let database = try LibraryDatabase(path: ":memory:")
        try await scan(a, id: "a", database: database)
        let indexed = try await database.files(FileQuery())
        let itemID = try XCTUnwrap(indexed.files.first?.id)
        let vault = root.appendingPathComponent("Vault")
        let store = ManagedFileStore(root: vault)
        try FileManager.default.moveItem(at: original, to: root.appendingPathComponent("moved.txt"))

        XCTAssertThrowsError(try store.copy(sourceURL: original))
        let savedFile = try await database.file(id: itemID)
        let saved = try XCTUnwrap(savedFile)
        XCTAssertNil(saved.managedCopyPath)
        XCTAssertNil(saved.managedSHA256)
        XCTAssertNil(saved.managedAt)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: vault.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testRemovingSourceKeepsLinkedMetadataAndArchiveWithoutTouchingOriginal() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try folder("A", in: root)
        let original = a.appendingPathComponent("订单.txt")
        let linkedOriginal = a.appendingPathComponent("设备说明.txt")
        let bytes = Data("synthetic original stays here".utf8)
        try bytes.write(to: original)
        try bytes.write(to: linkedOriginal)
        let database = try LibraryDatabase(path: root.appendingPathComponent("library.sqlite").path)
        try await scan(a, id: "a", database: database)
        let indexed = try await database.files(FileQuery())
        let itemID = try XCTUnwrap(indexed.files.first { $0.name == "订单.txt" }?.id)
        let linkedID = try XCTUnwrap(indexed.files.first { $0.name == "设备说明.txt" }?.id)
        try await database.saveObject(id: "computer", name: "我的电脑", kind: "device", notes: "")
        try await database.linkItems([linkedID], to: "computer")
        let store = ManagedFileStore(root: root.appendingPathComponent("Vault"))
        let copy = try store.copy(sourceURL: original)
        try await database.saveManagedCopy(itemID: itemID, relativePath: copy.relativePath, sha256: copy.sha256)

        try await database.removeSource("a")
        let sources = try await database.sources()
        let normalLibrary = try await database.files(FileQuery())
        let objectFiles = try await database.files(FileQuery(objectID: "computer"))
        let archivedFile = try await database.file(id: itemID)
        XCTAssertTrue(sources.isEmpty)
        XCTAssertEqual(normalLibrary.total, 0)
        XCTAssertEqual(objectFiles.files.first?.id, linkedID)
        XCTAssertEqual(objectFiles.files.first?.isAvailable, false)
        XCTAssertEqual(archivedFile?.managedCopyPath, copy.relativePath)
        XCTAssertEqual(archivedFile?.isAvailable, false)
        XCTAssertEqual(try Data(contentsOf: store.url(for: copy.relativePath)), bytes)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertEqual(try Data(contentsOf: linkedOriginal), bytes)

        try await scan(a, id: "a", database: database)
        let restored = try await database.files(FileQuery())
        let restoredObjects = try await database.objectsForItem(linkedID)
        XCTAssertEqual(Set(restored.files.map(\.id)), [itemID, linkedID])
        XCTAssertTrue(restored.files.allSatisfy(\.isAvailable))
        XCTAssertEqual(restoredObjects.map(\.id), ["computer"])
    }

    func testVaultRejectsTraversalAndSymlinks() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = try folder("Vault", in: root), outside = try folder("outside", in: root)
        let original = outside.appendingPathComponent("原件.txt")
        let bytes = Data("outside must remain unchanged".utf8)
        try bytes.write(to: original)
        let store = ManagedFileStore(root: vault)
        XCTAssertThrowsError(try store.url(for: "../outside/原件.txt"))
        XCTAssertThrowsError(try store.url(for: original.path))
        try FileManager.default.createSymbolicLink(at: vault.appendingPathComponent("linked-folder"),
                                                  withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: vault.appendingPathComponent("linked-file.txt"),
                                                  withDestinationURL: original)
        XCTAssertThrowsError(try store.url(for: "linked-folder/原件.txt"))
        XCTAssertThrowsError(try store.url(for: "linked-file.txt"))
        XCTAssertThrowsError(try store.copy(sourceURL: vault.appendingPathComponent("linked-file.txt")))
        let linkedRoot = root.appendingPathComponent("LinkedVault")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)
        let linkedStore = ManagedFileStore(root: linkedRoot)
        XCTAssertThrowsError(try linkedStore.url(for: "原件.txt"))
        XCTAssertThrowsError(try linkedStore.copy(sourceURL: original))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }
}
