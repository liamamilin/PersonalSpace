import GRDB
import XCTest
@testable import PersonalSpace

@MainActor
final class FullTextTests: XCTestCase {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func index(_ names: [String], database: LibraryDatabase) async throws -> [LibraryFile] {
        try await database.saveSource(id: "source", name: "合成测试来源",
            path: "/synthetic/full-text", bookmark: Data([1]))
        try database.saveBatch(names.map {
            ScannedFile(relativePath: $0, name: $0, typeIdentifier: "public.plain-text", bytes: 10)
        }, sourceID: "source", scanID: "seed")
        return try await database.files(FileQuery()).files
    }

    // Frozen released schemas exercise a real M3 database upgrade, including two files and orders.
    private func createM3Database(path: String) throws {
        let queue = try DatabaseQueue(path: path)
        let schemas: [(String, String)] = [
            ("M1-file-library", """
                CREATE TABLE source (
                    id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, path TEXT NOT NULL UNIQUE,
                    bookmark BLOB NOT NULL, lastScannedAt DATETIME, lastError TEXT
                );
                CREATE TABLE item (
                    id TEXT PRIMARY KEY NOT NULL,
                    sourceID TEXT NOT NULL REFERENCES source(id) ON DELETE CASCADE,
                    relativePath TEXT NOT NULL, name TEXT NOT NULL, typeIdentifier TEXT NOT NULL,
                    bytes INTEGER NOT NULL, modifiedAt DATETIME, createdAt DATETIME,
                    indexedAt DATETIME NOT NULL, scanID TEXT NOT NULL,
                    isAvailable BOOLEAN NOT NULL DEFAULT 1, UNIQUE(sourceID, relativePath)
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
                    id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('device', 'other')),
                    name TEXT NOT NULL CHECK(length(trim(name)) > 0), notes TEXT NOT NULL DEFAULT '',
                    createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL
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
                    id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL,
                    title TEXT NOT NULL CHECK(length(trim(title)) > 0),
                    status TEXT NOT NULL CHECK(status IN ('active', 'completed')),
                    objectID TEXT REFERENCES personal_object(id) ON DELETE SET NULL,
                    notes TEXT NOT NULL DEFAULT '', createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL
                );
                CREATE TABLE matter_item (
                    matterID TEXT NOT NULL REFERENCES matter(id) ON DELETE CASCADE,
                    itemID TEXT NOT NULL REFERENCES item(id) ON DELETE CASCADE, PRIMARY KEY(matterID, itemID)
                );
                CREATE INDEX matter_item_item ON matter_item(itemID);
                CREATE TABLE fact (
                    id TEXT PRIMARY KEY NOT NULL, matterID TEXT NOT NULL REFERENCES matter(id) ON DELETE CASCADE,
                    key TEXT NOT NULL, valueText TEXT NOT NULL,
                    valueType TEXT NOT NULL CHECK(valueType IN ('text', 'date', 'amount')),
                    state TEXT NOT NULL CHECK(state IN ('candidate', 'confirmed')),
                    sourceItemID TEXT REFERENCES item(id) ON DELETE SET NULL, sourceExcerpt TEXT,
                    origin TEXT NOT NULL CHECK(origin IN ('ocr', 'model', 'user'))
                );
                CREATE INDEX fact_matter ON fact(matterID);
                CREATE TABLE action (
                    id TEXT PRIMARY KEY NOT NULL, matterID TEXT REFERENCES matter(id) ON DELETE SET NULL,
                    title TEXT NOT NULL CHECK(length(trim(title)) > 0), dueDate DATETIME, remindAt DATETIME,
                    state TEXT NOT NULL CHECK(state IN ('needs_date', 'active', 'done', 'cancelled')),
                    dateConfirmed BOOLEAN NOT NULL DEFAULT 0, createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL,
                    CHECK(dateConfirmed=1 OR remindAt IS NULL),
                    CHECK(state<>'active' OR (dateConfirmed=1 AND remindAt IS NOT NULL))
                );
                CREATE INDEX action_matter ON action(matterID);
                CREATE INDEX action_reminder ON action(state, remindAt);
                """)
        ]
        var migrator = DatabaseMigrator()
        for (name, sql) in schemas {
            migrator.registerMigration(name) { db in try db.execute(sql: sql) }
        }
        try migrator.migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO source(id, name, path, bookmark) VALUES ('legacy', 'M3 来源', '/synthetic/m3', X'01');
                INSERT INTO item(id, sourceID, relativePath, name, typeIdentifier, bytes, indexedAt, scanID)
                VALUES ('receipt-a', 'legacy', '原凭证.txt', '原凭证.txt', 'public.plain-text', 10, '2026-10-28', 'm3'),
                       ('receipt-b', 'legacy', '另一凭证.txt', '另一凭证.txt', 'public.plain-text', 20, '2026-10-28', 'm3');
                INSERT INTO personal_object(id, kind, name, notes, createdAt, updatedAt)
                VALUES ('computer', 'device', '原有设备', '', '2026-10-28', '2026-10-28');
                INSERT INTO object_item(objectID, itemID) VALUES ('computer', 'receipt-a');
                INSERT INTO matter(id, kind, title, status, objectID, notes, createdAt, updatedAt)
                VALUES ('order-a', 'order', '原订单 A', 'active', 'computer', '旧备注', '2026-10-28', '2026-10-28'),
                       ('order-b', 'order', '原订单 B', 'active', NULL, '', '2026-10-28', '2026-10-28');
                INSERT INTO matter_item(matterID, itemID) VALUES ('order-a', 'receipt-a'), ('order-b', 'receipt-b');
                INSERT INTO fact(id, matterID, key, valueText, valueType, state, sourceItemID, sourceExcerpt, origin)
                VALUES ('old-fact', 'order-a', 'merchant', '旧商家', 'text', 'candidate', 'receipt-a', '商家：旧商家', 'ocr');
                INSERT INTO action(id, matterID, title, state, dateConfirmed, createdAt, updatedAt)
                VALUES ('old-action', 'order-a', '原待办', 'needs_date', 0, '2026-10-28', '2026-10-28');
                """)
        }
    }

    func testM3UpgradeKeepsTwoFilesOrdersFactsAndActionAndAddsEmptyTextIndex() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("library.sqlite").path
        try createM3Database(path: path)
        let database = try LibraryDatabase(path: path)
        let files = try await database.files(FileQuery())
        let matters = try await database.matters()
        let facts = try await database.facts(matterID: "order-a")
        let action = try await database.action(id: "old-action")
        let objects = try await database.objects()
        XCTAssertEqual(Set(files.files.map(\.id)), ["receipt-a", "receipt-b"])
        XCTAssertEqual(Set(matters.map(\.id)), ["order-a", "order-b"])
        XCTAssertEqual(facts.first?.valueText, "旧商家")
        XCTAssertEqual(facts.first?.sourceItemID, "receipt-a")
        XCTAssertEqual(action?.state, "needs_date")
        XCTAssertEqual(objects.first?.itemCount, 1)
        XCTAssertTrue(files.files.allSatisfy { $0.textIndexedAt == nil })
        let noText = try await database.documentText(itemID: "receipt-a")
        XCTAssertNil(noText)
        try await database.saveDocumentText(itemID: "receipt-a", text: "升级后显式允许的星云正文")
        let found = try await database.files(FileQuery(search: "星云正文", searchBody: true))
        XCTAssertEqual(found.files.map(\.id), ["receipt-a"])
    }

    func testBodySearchRequiresExplicitOptInAndUsesRealTrigramFTS() async throws {
        let database = try LibraryDatabase(path: ":memory:")
        let files = try await index(["普通凭证.txt", "其它资料.txt"], database: database)
        let receipt = try XCTUnwrap(files.first { $0.name == "普通凭证.txt" })
        let text = "设备原始交易记录包括 nebulaquartz 以及专属星云凭证；这些词不在文件名里。"
        try await database.saveDocumentText(itemID: receipt.id, text: text)
        let normal = try await database.files(FileQuery(search: "nebulaquartz"))
        let body = try await database.files(FileQuery(search: "nebulaquartz", searchBody: true))
        let chinese = try await database.files(FileQuery(search: "专属星云", searchBody: true))
        let both = try await database.files(FileQuery(search: "nebulaquartz 普通", searchBody: true))
        XCTAssertEqual(normal.total, 0)
        XCTAssertEqual(body.files.map(\.id), [receipt.id])
        XCTAssertEqual(chinese.files.map(\.id), [receipt.id])
        XCTAssertEqual(both.files.map(\.id), [receipt.id])
        XCTAssertNotNil(body.files.first?.textIndexedAt)
        let savedText = try await database.documentText(itemID: receipt.id)
        XCTAssertEqual(savedText, text)
        let ftsRows = try await database.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM document_text_fts WHERE document_text_fts MATCH ?",
                             arguments: ["\"nebulaquartz\""])
        }
        XCTAssertEqual(ftsRows, 1)
    }

    func testChineseShortQueriesAndLiteralSpecialCharactersAreUsefulAndSafe() async throws {
        let database = try LibraryDatabase(path: ":memory:")
        let files = try await index(["合同资料.txt", "普通资料.txt"], database: database)
        let bodyItem = try XCTUnwrap(files.first { $0.name == "普通资料.txt" })
        try await database.saveDocumentText(itemID: bodyItem.id, text: "星云服务金额为100%_，含\"引号\"与 O'Reilly 标签")
        let metadata = try await database.files(FileQuery(search: "合同"))
        let shortChinese = try await database.files(FileQuery(search: "星云", searchBody: true))
        let oneCharacter = try await database.files(FileQuery(search: "星", searchBody: true))
        let literal = try await database.files(FileQuery(search: "%_", searchBody: true))
        XCTAssertEqual(metadata.files.first?.name, "合同资料.txt")
        XCTAssertEqual(shortChinese.files.map(\.id), [bodyItem.id])
        XCTAssertEqual(oneCharacter.files.map(\.id), [bodyItem.id])
        XCTAssertEqual(literal.files.map(\.id), [bodyItem.id])
        for query in ["\"", "\"\"\"", "a\"b", "OR", "NEAR(x)", "*", "O'Reilly", "\" OR *"] {
            _ = try await database.files(FileQuery(search: query, searchBody: true))
        }
    }

    func testReplacingAndDeletingTextRemoveOldFTSMatches() async throws {
        let database = try LibraryDatabase(path: ":memory:")
        let indexed = try await index(["普通资料.txt"], database: database)
        let item = try XCTUnwrap(indexed.first)
        try await database.saveDocumentText(itemID: item.id, text: "oldquartz 原正文")
        try await database.saveDocumentText(itemID: item.id, text: "newnebula 新正文")
        let old = try await database.files(FileQuery(search: "oldquartz", searchBody: true))
        let replacement = try await database.files(FileQuery(search: "newnebula", searchBody: true))
        let saved = try await database.documentText(itemID: item.id)
        XCTAssertEqual(old.total, 0)
        XCTAssertEqual(replacement.total, 1)
        XCTAssertEqual(saved, "newnebula 新正文")

        try await database.deleteDocumentText(itemID: item.id)
        let deleted = try await database.files(FileQuery(search: "newnebula", searchBody: true))
        let noText = try await database.documentText(itemID: item.id)
        let remainingFile = try await database.file(id: item.id)
        let staleFTS = try await database.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM document_text_fts WHERE document_text_fts MATCH ?",
                             arguments: ["\"newnebula\""])
        }
        XCTAssertEqual(deleted.total, 0)
        XCTAssertNil(noText)
        XCTAssertNil(remainingFile?.textIndexedAt)
        XCTAssertEqual(staleFTS, 0)
        XCTAssertNotNil(remainingFile)
    }

    func testSensitiveNamesAndOversizeTextCannotEnterIndex() async throws {
        let database = try LibraryDatabase(path: ":memory:")
        let files = try await index(["账号密码.txt", "recovery-code.txt", "普通资料.txt"], database: database)
        for item in files where item.name != "普通资料.txt" {
            do {
                try await database.saveDocumentText(itemID: item.id, text: "forbiddensecrettext")
                XCTFail("Sensitive filename unexpectedly indexed")
            } catch { }
            let text = try await database.documentText(itemID: item.id)
            let saved = try await database.file(id: item.id)
            XCTAssertNil(text)
            XCTAssertNil(saved?.textIndexedAt)
        }
        let normal = try XCTUnwrap(files.first { $0.name == "普通资料.txt" })
        try await database.saveDocumentText(itemID: normal.id, text: "previousallowedtext")
        do {
            try await database.saveDocumentText(itemID: normal.id, text: String(repeating: "长", count: 200_001))
            XCTFail("Oversized body unexpectedly indexed")
        } catch { }
        let preserved = try await database.documentText(itemID: normal.id)
        let forbidden = try await database.files(FileQuery(search: "forbiddensecrettext", searchBody: true))
        XCTAssertEqual(preserved, "previousallowedtext")
        XCTAssertEqual(forbidden.total, 0)
    }

    func testAllFourMatterKindsPersistWithFactsEvidenceAndConfirmedActions() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("library.sqlite").path
        let database = try LibraryDatabase(path: path)
        let indexed = try await index(["普通凭证.txt"], database: database)
        let item = try XCTUnwrap(indexed.first)
        for kind in ["order", "contract", "warranty", "subscription"] {
            let draft = MatterDraft(id: kind, kind: kind, title: "合成 \(kind)", itemIDs: [item.id], facts: [
                FactDraft(key: "end_date", valueText: "2027-10-28", valueType: "date", state: "confirmed")
            ], action: ActionDraft(id: "action-" + kind, title: "人工确认的跟进",
                remindAt: Date(timeIntervalSince1970: 1_900_000_000), state: "active", dateConfirmed: true))
            try await database.saveMatter(draft)
        }
        let reopened = try LibraryDatabase(path: path)
        let matters = try await reopened.matters()
        XCTAssertEqual(Set(matters.map(\.kind)), ["order", "contract", "warranty", "subscription"])
        XCTAssertTrue(matters.allSatisfy { $0.itemCount == 1 })
        for kind in ["order", "contract", "warranty", "subscription"] {
            let facts = try await reopened.facts(matterID: kind)
            let action = try await reopened.action(id: "action-" + kind)
            let files = try await reopened.files(FileQuery(matterID: kind))
            XCTAssertEqual(facts.first?.valueText, "2027-10-28")
            XCTAssertEqual(facts.first?.state, "confirmed")
            XCTAssertEqual(action?.state, "active")
            XCTAssertEqual(action?.dateConfirmed, true)
            XCTAssertEqual(files.files.first?.id, item.id)
        }
    }
}
