import GRDB
import XCTest
@testable import PersonalSpace

@MainActor
final class PhotoAndSensitivityTests: XCTestCase {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func index(_ names: [String], database: LibraryDatabase) async throws -> [LibraryFile] {
        try await database.saveSource(id: "folder", name: "合成文件来源", path: "/synthetic/m5", bookmark: Data([1]))
        try database.saveBatch(names.map {
            ScannedFile(relativePath: $0, name: $0, typeIdentifier: "public.plain-text", bytes: 10)
        }, sourceID: "folder", scanID: "seed")
        return try await database.files(FileQuery()).files
    }

    // Frozen M4 migration SQL keeps this independent from the new M5 migration implementation.
    private func createM4Database(path: String) throws {
        let queue = try DatabaseQueue(path: path)
        let schemas: [(String, String)] = [
            ("M1-file-library", """
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
                """),
            ("M2-objects-managed-copies", """
                ALTER TABLE source ADD COLUMN isEnabled BOOLEAN NOT NULL DEFAULT 1;
                ALTER TABLE item ADD COLUMN managedCopyPath TEXT;
                ALTER TABLE item ADD COLUMN managedSHA256 TEXT;
                ALTER TABLE item ADD COLUMN managedAt DATETIME;
                CREATE TABLE personal_object (
                    id TEXT PRIMARY KEY NOT NULL,
                    kind TEXT NOT NULL CHECK(kind IN ('device', 'other')),
                    name TEXT NOT NULL CHECK(length(trim(name)) > 0),
                    notes TEXT NOT NULL DEFAULT '',
                    createdAt DATETIME NOT NULL,
                    updatedAt DATETIME NOT NULL
                );
                CREATE TABLE object_item (
                    objectID TEXT NOT NULL REFERENCES personal_object(id) ON DELETE CASCADE,
                    itemID TEXT NOT NULL REFERENCES item(id) ON DELETE CASCADE,
                    PRIMARY KEY(objectID, itemID)
                );
                CREATE INDEX object_item_item ON object_item(itemID);
                """),
            ("M3-orders-facts-actions", """
                CREATE TABLE matter (
                    id TEXT PRIMARY KEY NOT NULL,
                    kind TEXT NOT NULL,
                    title TEXT NOT NULL CHECK(length(trim(title)) > 0),
                    status TEXT NOT NULL CHECK(status IN ('active', 'completed')),
                    objectID TEXT REFERENCES personal_object(id) ON DELETE SET NULL,
                    notes TEXT NOT NULL DEFAULT '',
                    createdAt DATETIME NOT NULL,
                    updatedAt DATETIME NOT NULL
                );
                CREATE TABLE matter_item (
                    matterID TEXT NOT NULL REFERENCES matter(id) ON DELETE CASCADE,
                    itemID TEXT NOT NULL REFERENCES item(id) ON DELETE CASCADE,
                    PRIMARY KEY(matterID, itemID)
                );
                CREATE INDEX matter_item_item ON matter_item(itemID);
                CREATE TABLE fact (
                    id TEXT PRIMARY KEY NOT NULL,
                    matterID TEXT NOT NULL REFERENCES matter(id) ON DELETE CASCADE,
                    key TEXT NOT NULL,
                    valueText TEXT NOT NULL,
                    valueType TEXT NOT NULL CHECK(valueType IN ('text', 'date', 'amount')),
                    state TEXT NOT NULL CHECK(state IN ('candidate', 'confirmed')),
                    sourceItemID TEXT REFERENCES item(id) ON DELETE SET NULL,
                    sourceExcerpt TEXT,
                    origin TEXT NOT NULL CHECK(origin IN ('ocr', 'model', 'user'))
                );
                CREATE INDEX fact_matter ON fact(matterID);
                CREATE TABLE action (
                    id TEXT PRIMARY KEY NOT NULL,
                    matterID TEXT REFERENCES matter(id) ON DELETE SET NULL,
                    title TEXT NOT NULL CHECK(length(trim(title)) > 0),
                    dueDate DATETIME,
                    remindAt DATETIME,
                    state TEXT NOT NULL CHECK(state IN ('needs_date', 'active', 'done', 'cancelled')),
                    dateConfirmed BOOLEAN NOT NULL DEFAULT 0,
                    createdAt DATETIME NOT NULL,
                    updatedAt DATETIME NOT NULL,
                    CHECK(dateConfirmed=1 OR remindAt IS NULL),
                    CHECK(state<>'active' OR (dateConfirmed=1 AND remindAt IS NOT NULL))
                );
                CREATE INDEX action_matter ON action(matterID);
                CREATE INDEX action_reminder ON action(state, remindAt);
                """),
            ("M4-explicit-document-text", """
                CREATE TABLE document_text (
                    itemID TEXT PRIMARY KEY NOT NULL REFERENCES item(id) ON DELETE CASCADE,
                    bodyText TEXT NOT NULL,
                    indexedAt DATETIME NOT NULL
                );
                CREATE VIRTUAL TABLE document_text_fts USING fts5(
                    bodyText, content='document_text', content_rowid='rowid', tokenize='trigram'
                );
                CREATE TRIGGER document_text_insert AFTER INSERT ON document_text BEGIN
                    INSERT INTO document_text_fts(rowid, bodyText) VALUES (new.rowid, new.bodyText);
                END;
                CREATE TRIGGER document_text_delete AFTER DELETE ON document_text BEGIN
                    INSERT INTO document_text_fts(document_text_fts, rowid, bodyText)
                    VALUES ('delete', old.rowid, old.bodyText);
                END;
                CREATE TRIGGER document_text_update AFTER UPDATE ON document_text BEGIN
                    INSERT INTO document_text_fts(document_text_fts, rowid, bodyText)
                    VALUES ('delete', old.rowid, old.bodyText);
                    INSERT INTO document_text_fts(rowid, bodyText) VALUES (new.rowid, new.bodyText);
                END;
                """)
        ]
        var migrator = DatabaseMigrator()
        for (name, sql) in schemas {
            migrator.registerMigration(name) { db in try db.execute(sql: sql) }
        }
        try migrator.migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO source(id, name, path, bookmark) VALUES ('legacy', 'M4 来源', '/synthetic/m4', X'01');
                INSERT INTO item(id, sourceID, relativePath, name, typeIdentifier, bytes, indexedAt, scanID)
                VALUES ('ordinary', 'legacy', '订单.txt', '订单.txt', 'public.plain-text', 10, '2026-10-28', 'm4'),
                       ('suspect', 'legacy', '账号密码.txt', '账号密码.txt', 'public.plain-text', 20, '2026-10-28', 'm4');
                INSERT INTO personal_object(id, kind, name, notes, createdAt, updatedAt)
                VALUES ('computer', 'device', '旧设备', '', '2026-10-28', '2026-10-28');
                INSERT INTO object_item(objectID, itemID) VALUES ('computer', 'ordinary'), ('computer', 'suspect');
                INSERT INTO document_text(itemID, bodyText, indexedAt)
                VALUES ('ordinary', 'ordinarylegacytext', '2026-10-28'),
                       ('suspect', 'suspectlegacytext', '2026-10-28');
                """)
        }
    }

    func testM4UpgradeClassifiesTwoExistingRecordsAndClearsOnlySensitiveBodyIndex() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("library.sqlite").path
        try createM4Database(path: path)
        let database = try LibraryDatabase(path: path)
        let files = try await database.files(FileQuery())
        let ordinary = try await database.file(id: "ordinary")
        let suspect = try await database.file(id: "suspect")
        let objects = try await database.objects()
        let ordinaryText = try await database.documentText(itemID: "ordinary")
        let suspectText = try await database.documentText(itemID: "suspect")
        let foundOrdinary = try await database.files(FileQuery(search: "ordinarylegacytext", searchBody: true))
        let foundSuspect = try await database.files(FileQuery(search: "suspectlegacytext", searchBody: true))
        XCTAssertEqual(Set(files.files.map(\.id)), ["ordinary", "suspect"])
        XCTAssertEqual(ordinary?.itemKind, "file")
        XCTAssertEqual(ordinary?.sensitivity, "normal")
        XCTAssertEqual(suspect?.sensitivity, "suspected")
        XCTAssertNil(suspect?.photoLocalIdentifier)
        XCTAssertEqual(objects.first?.itemCount, 2)
        XCTAssertEqual(ordinaryText, "ordinarylegacytext")
        XCTAssertNil(suspectText)
        XCTAssertNotNil(ordinary?.textIndexedAt)
        XCTAssertNil(suspect?.textIndexedAt)
        XCTAssertEqual(foundOrdinary.total, 1)
        XCTAssertEqual(foundSuspect.total, 0)
        let suspectFTS = try await database.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM document_text_fts WHERE document_text_fts MATCH ?",
                             arguments: ["\"suspectlegacytext\""])
        }
        XCTAssertEqual(suspectFTS, 0)
    }

    func testPhotoUpsertRestartAndRelationsKeepStableIDsWithoutCreatingFolderSources() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("library.sqlite").path
        let database = try LibraryDatabase(path: path)
        _ = try await index(["普通文件.txt"], database: database)
        let created = Date(timeIntervalSince1970: 1_798_113_600)
        try await database.savePhotos([
            ScannedPhoto(localIdentifier: "asset-a/L0/001", name: "设备照片", createdAt: created, modifiedAt: created),
            ScannedPhoto(localIdentifier: "asset-b/L0/001", name: "另一照片")
        ])
        let initial = try await database.files(FileQuery(sourceID: "photos"))
        let first = try XCTUnwrap(initial.files.first { $0.photoLocalIdentifier == "asset-a/L0/001" })
        let second = try XCTUnwrap(initial.files.first { $0.photoLocalIdentifier == "asset-b/L0/001" })
        try await database.saveObject(id: "computer", name: "我的电脑", kind: "device", notes: "")
        try await database.linkItems([first.id], to: "computer")
        try await database.savePhotos([ScannedPhoto(localIdentifier: "asset-a/L0/001", name: "更新后的照片",
            createdAt: created, modifiedAt: created.addingTimeInterval(60))])

        let reopened = try LibraryDatabase(path: path)
        let all = try await reopened.files(FileQuery())
        let photos = try await reopened.files(FileQuery(sourceID: "photos"))
        let sources = try await reopened.sources()
        let notAFolder = try await reopened.findSource(path: "photos://system-library")
        let owners = try await reopened.objectsForItem(first.id)
        let updated = try await reopened.file(id: first.id)
        XCTAssertEqual(all.total, 3)
        XCTAssertEqual(Set(photos.files.map(\.id)), [first.id, second.id])
        XCTAssertEqual(sources.map(\.id), ["folder"])
        XCTAssertNil(notAFolder)
        XCTAssertEqual(owners.first?.id, "computer")
        XCTAssertEqual(updated?.name, "更新后的照片")
        XCTAssertEqual(updated?.modifiedAt, created.addingTimeInterval(60))
        XCTAssertEqual(updated?.photoLocalIdentifier, "asset-a/L0/001")
        XCTAssertEqual(updated?.isPhoto, true)
        XCTAssertEqual(updated?.kind, "照片")
        XCTAssertEqual(updated?.size, "—")
        XCTAssertEqual(updated?.fullPath, "照片图库")
        XCTAssertEqual(updated?.isAvailable, true)
        XCTAssertThrowsError(try reopened.saveBatch([], sourceID: "photos", scanID: "must-not-scan"))
        XCTAssertThrowsError(try reopened.finishScan(sourceID: "photos", scanID: "must-not-scan"))
    }

    func testLostPhotoPermissionKeepsUnavailableObjectPlaceholderAndOnlyVerifiedAssetsRecover() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("library.sqlite").path
        let database = try LibraryDatabase(path: path)
        try await database.savePhotos([
            ScannedPhoto(localIdentifier: "asset-a", name: "设备照片"),
            ScannedPhoto(localIdentifier: "asset-b", name: "其它照片")
        ])
        let photos = try await database.files(FileQuery(sourceID: "photos"))
        let first = try XCTUnwrap(photos.files.first { $0.photoLocalIdentifier == "asset-a" })
        let second = try XCTUnwrap(photos.files.first { $0.photoLocalIdentifier == "asset-b" })
        try await database.saveObject(id: "computer", name: "我的电脑", kind: "device", notes: "")
        try await database.linkItems([first.id], to: "computer")
        try await database.setPhotosAccess(allowed: false, message: "照片授权已撤回，请重新授权。")
        let reopened = try LibraryDatabase(path: path)
        let normal = try await reopened.files(FileQuery())
        let linked = try await reopened.files(FileQuery(objectID: "computer"))
        XCTAssertEqual(normal.total, 0)
        XCTAssertEqual(linked.files.first?.id, first.id)
        XCTAssertEqual(linked.files.first?.isAvailable, false)
        XCTAssertEqual(linked.files.first?.photoLocalIdentifier, "asset-a")
        XCTAssertEqual(linked.files.first?.sourceError, "照片授权已撤回，请重新授权。")

        try await reopened.setPhotosAccess(allowed: true)
        let notYetVerified = try await reopened.file(id: first.id)
        XCTAssertEqual(notYetVerified?.isAvailable, false)
        try await reopened.savePhotos([ScannedPhoto(localIdentifier: "asset-a", name: "设备照片")])
        let verified = try await reopened.file(id: first.id)
        let stillUnavailable = try await reopened.file(id: second.id)
        XCTAssertEqual(verified?.isAvailable, true)
        XCTAssertEqual(stillUnavailable?.isAvailable, false)
        let retainedOwners = try await reopened.objectsForItem(first.id)
        XCTAssertEqual(retainedOwners.first?.id, "computer")
    }

    func testMarkingSensitiveAtomicallyClearsTextAndFTSButKeepsExistingFacts() async throws {
        let database = try LibraryDatabase(path: ":memory:")
        let indexed = try await index(["普通资料.txt"], database: database)
        let item = try XCTUnwrap(indexed.first)
        try await database.saveDocumentText(itemID: item.id, text: "classifiednebula 正文")
        try await database.saveMatter(MatterDraft(id: "order", title: "原事务", itemIDs: [item.id], facts: [
            FactDraft(key: "merchant", valueText: "合成商家", sourceItemID: item.id)
        ]))
        for state in ["suspected", "sensitive"] {
            try await database.setSensitivity(itemID: item.id, state: state)
            let text = try await database.documentText(itemID: item.id)
            let file = try await database.file(id: item.id)
            let found = try await database.files(FileQuery(search: "classifiednebula", searchBody: true))
            let facts = try await database.facts(matterID: "order")
            let rows = try await database.queue.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM document_text WHERE itemID=?", arguments: [item.id])
            }
            XCTAssertEqual(file?.sensitivity, state)
            XCTAssertNil(text)
            XCTAssertNil(file?.textIndexedAt)
            XCTAssertEqual(found.total, 0)
            XCTAssertEqual(rows, 0)
            XCTAssertEqual(facts.first?.valueText, "合成商家")
            do {
                try await database.saveDocumentText(itemID: item.id, text: "classifiednebula")
                XCTFail("Non-normal item unexpectedly indexed")
            } catch { }
            try await database.setSensitivity(itemID: item.id, state: "normal")
            let notRebuilt = try await database.documentText(itemID: item.id)
            XCTAssertNil(notRebuilt)
            try await database.saveDocumentText(itemID: item.id, text: "classifiednebula 正文")
        }
    }

    func testManualNormalOverridesFilenameDetectionAndRefreshPreservesClassification() async throws {
        let database = try LibraryDatabase(path: ":memory:")
        let files = try await index(["账号密码.txt", "普通资料.txt"], database: database)
        let suspect = try XCTUnwrap(files.first { $0.name == "账号密码.txt" })
        let normal = try XCTUnwrap(files.first { $0.name == "普通资料.txt" })
        XCTAssertEqual(suspect.sensitivity, "suspected")
        do {
            try await database.saveDocumentText(itemID: suspect.id, text: "explicitlyapprovedtext")
            XCTFail("Suspected file unexpectedly indexed before user override")
        } catch { }
        try await database.setSensitivity(itemID: suspect.id, state: "normal")
        try await database.saveDocumentText(itemID: suspect.id, text: "explicitlyapprovedtext")
        try await database.setSensitivity(itemID: normal.id, state: "sensitive")
        _ = try await index(["账号密码.txt", "普通资料.txt", "recovery-code.txt"], database: database)
        let refreshedSuspect = try await database.file(id: suspect.id)
        let refreshedNormal = try await database.file(id: normal.id)
        let approvedText = try await database.documentText(itemID: suspect.id)
        let newSuspect = try await database.files(FileQuery(search: "recovery-code"))
        XCTAssertEqual(refreshedSuspect?.sensitivity, "normal")
        XCTAssertEqual(refreshedNormal?.sensitivity, "sensitive")
        XCTAssertEqual(approvedText, "explicitlyapprovedtext")
        XCTAssertEqual(newSuspect.files.first?.sensitivity, "suspected")
    }
}
