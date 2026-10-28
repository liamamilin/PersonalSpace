import CryptoKit
import GRDB
import XCTest
@testable import PersonalSpace

@MainActor
final class MatterTests: XCTestCase {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func evidence(database: LibraryDatabase, root: URL) async throws -> LibraryFile {
        let folder = root.appendingPathComponent("授权来源", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bytes = Data("合成订单测试凭证，非个人资料".utf8)
        try bytes.write(to: folder.appendingPathComponent("订单.txt"))
        try await database.saveSource(id: "source", name: "授权来源", path: folder.path, bookmark: Data([1]))
        try database.saveBatch([ScannedFile(relativePath: "订单.txt", name: "订单.txt",
            typeIdentifier: "public.plain-text", bytes: Int64(bytes.count))], sourceID: "source", scanID: "test")
        let indexed = try await database.files(FileQuery())
        return try XCTUnwrap(indexed.files.first)
    }

    private func expectSaveFailure(_ draft: MatterDraft, database: LibraryDatabase,
                                   file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await database.saveMatter(draft)
            XCTFail("Invalid draft unexpectedly saved", file: file, line: line)
        } catch { }
    }

    // Exact released M1/M2 schemas and migration IDs exercise an upgrade, not fresh creation.
    private func createM2Database(path: String, managedPath: String, sha256: String) throws {
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
        migrator.registerMigration("M2-objects-managed-copies") { db in
            try db.execute(sql: """
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
                """)
        }
        try migrator.migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO source(id, name, path, bookmark)
                VALUES ('legacy-source', 'M2 来源', '/synthetic/m2', X'01');
                INSERT INTO item(id, sourceID, relativePath, name, typeIdentifier, bytes, indexedAt, scanID)
                VALUES ('legacy-order', 'legacy-source', '订单.txt', '订单.txt', 'public.plain-text', 10,
                        '2026-10-28 01:00:00', 'm2-scan'),
                       ('legacy-invoice', 'legacy-source', '发票.txt', '发票.txt', 'public.plain-text', 20,
                        '2026-10-28 01:00:00', 'm2-scan');
                INSERT INTO personal_object(id, kind, name, notes, createdAt, updatedAt)
                VALUES ('computer', 'device', '我的电脑', 'M2 备注',
                        '2026-10-28 01:00:00', '2026-10-28 01:00:00');
                INSERT INTO object_item(objectID, itemID)
                VALUES ('computer', 'legacy-order'), ('computer', 'legacy-invoice');
                """)
            try db.execute(sql: """
                UPDATE item SET managedCopyPath=?, managedSHA256=?, managedAt=? WHERE id='legacy-order'
                """, arguments: [managedPath, sha256, Date(timeIntervalSince1970: 1_798_113_600)])
        }
    }

    func testM2MigrationKeepsObjectLinksAndManagedCopy() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ManagedFileStore(root: root.appendingPathComponent("Vault"))
        let original = root.appendingPathComponent("原件.txt")
        let bytes = Data("M2 synthetic managed receipt".utf8)
        try bytes.write(to: original)
        let copy = try store.copy(sourceURL: original)
        let path = root.appendingPathComponent("library.sqlite").path
        try createM2Database(path: path, managedPath: copy.relativePath, sha256: copy.sha256)

        let database = try LibraryDatabase(path: path)
        let objects = try await database.objects()
        let linked = try await database.files(FileQuery(objectID: "computer"))
        let archived = try await database.file(id: "legacy-order")
        XCTAssertEqual(objects.first?.name, "我的电脑")
        XCTAssertEqual(objects.first?.notes, "M2 备注")
        XCTAssertEqual(objects.first?.itemCount, 2)
        XCTAssertEqual(Set(linked.files.map(\.id)), ["legacy-order", "legacy-invoice"])
        XCTAssertEqual(archived?.managedCopyPath, copy.relativePath)
        XCTAssertEqual(archived?.managedSHA256, copy.sha256)
        XCTAssertNotNil(archived?.managedAt)
        XCTAssertEqual(try Data(contentsOf: store.url(for: copy.relativePath)), bytes)

        let draft = MatterDraft(id: "order", title: "升级后的订单", objectID: "computer",
                                itemIDs: ["legacy-order", "legacy-invoice"])
        try await database.saveMatter(draft)
        let matter = try await database.matter(id: "order")
        XCTAssertEqual(matter?.itemCount, 2)
        XCTAssertEqual(matter?.objectID, "computer")
    }

    func testOrderEvidenceAndCandidateFactsPersistWithoutScheduling() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("library.sqlite").path
        let database = try LibraryDatabase(path: path)
        let item = try await evidence(database: database, root: root)
        let fact = FactDraft(id: "purchase-date", key: "purchaseDate", valueText: "2026-10-28",
            valueType: "date", sourceItemID: item.id, sourceExcerpt: "购买日期：2026-10-28", origin: "ocr")
        let draft = MatterDraft(id: "order", title: "设备订单", notes: "人工复核前",
            itemIDs: [item.id], facts: [fact], actions: [ActionDraft(id: "follow-up", title: "检查售后日期")])
        let action = try await database.saveMatter(draft).first
        XCTAssertEqual(action?.state, "needs_date")
        XCTAssertNil(action?.dueDate)
        XCTAssertNil(action?.remindAt)

        let reopened = try LibraryDatabase(path: path)
        let matters = try await reopened.matters(search: "设备")
        let facts = try await reopened.facts(matterID: "order")
        let linked = try await reopened.files(FileQuery(matterID: "order"))
        let actions = try await reopened.actions(matterID: "order")
        XCTAssertEqual(matters.map(\.id), ["order"])
        XCTAssertEqual(matters.first?.notes, "人工复核前")
        XCTAssertEqual(matters.first?.itemCount, 1)
        XCTAssertEqual(facts.first?.state, "candidate")
        XCTAssertEqual(facts.first?.valueText, "2026-10-28")
        XCTAssertEqual(facts.first?.sourceItemID, item.id)
        XCTAssertEqual(facts.first?.sourceExcerpt, "购买日期：2026-10-28")
        XCTAssertEqual(facts.first?.origin, "ocr")
        XCTAssertEqual(linked.files.map(\.id), [item.id])
        XCTAssertEqual(actions.first?.matterTitle, "设备订单")
        XCTAssertFalse(actions.first?.dateConfirmed ?? true)
        // A purchase-date candidate never becomes an inferred return deadline.
        XCTAssertNil(actions.first?.dueDate)
        XCTAssertNil(actions.first?.remindAt)

        try await reopened.removeSource(item.sourceID)
        let retained = try await reopened.files(FileQuery(matterID: "order"))
        XCTAssertEqual(retained.files.first?.id, item.id)
        XCTAssertEqual(retained.files.first?.isAvailable, false)
    }

    func testUnconfirmedPendingReminderAlwaysNeedsDateRegardlessOfRequestedState() async throws {
        let database = try LibraryDatabase(path: ":memory:")
        let requested = Date(timeIntervalSince1970: 1_900_000_000)
        for state in ["needs_date", "active"] {
            let draft = MatterDraft(id: state, title: "手工订单 \(state)", actions: [ActionDraft(
                title: "待补充日期", dueDate: requested, remindAt: requested,
                state: state, dateConfirmed: false)])
            let action = try await database.saveMatter(draft).first
            XCTAssertEqual(action?.state, "needs_date")
            XCTAssertNil(action?.remindAt)
            XCTAssertEqual(action?.dateConfirmed, false)
        }
        let draft = MatterDraft(id: "no-time", title: "没有具体提醒时间", actions: [ActionDraft(
            title: "补充提醒时间", state: "active", dateConfirmed: true)])
        let noTime = try await database.saveMatter(draft).first
        XCTAssertEqual(noTime?.state, "needs_date")
        XCTAssertNil(noTime?.remindAt)
    }

    func testEditingKeepsActionIDAndOmittedActionsStayUnchanged() async throws {
        let database = try LibraryDatabase(path: ":memory:")
        let firstTime = Date(timeIntervalSince1970: 1_900_000_000)
        var draft = MatterDraft(id: "order", title: "我的订单", actions: [ActionDraft(id: "stable-action",
            title: "第一次提醒", remindAt: firstTime, state: "active", dateConfirmed: true)])
        let first = try await database.saveMatter(draft).first
        draft.title = "已修改的订单"
        draft.actions[0] = ActionDraft(id: "stable-action", title: "改后的提醒",
            remindAt: firstTime.addingTimeInterval(3600), state: "active", dateConfirmed: true)
        let edited = try await database.saveMatter(draft).first
        let allActions = try await database.actions(matterID: "order")
        XCTAssertEqual(edited?.id, "stable-action")
        XCTAssertEqual(edited?.createdAt, first?.createdAt)
        XCTAssertEqual(edited?.remindAt, firstTime.addingTimeInterval(3600))
        XCTAssertEqual(edited?.matterTitle, "已修改的订单")
        XCTAssertEqual(allActions.count, 1)

        draft.actions = []
        let removed = try await database.saveMatter(draft)
        let cancelled = try await database.action(id: "stable-action")
        XCTAssertEqual(removed.count, 0)
        XCTAssertEqual(cancelled?.state, "active")
        XCTAssertEqual(cancelled?.matterID, "order")
    }

    func testCompletingAndCancellingActionsKeepStableRecords() async throws {
        let database = try LibraryDatabase(path: ":memory:")
        let draft = MatterDraft(id: "order", title: "手工订单", actions: [ActionDraft(id: "action",
            title: "跟进售后", remindAt: Date(timeIntervalSince1970: 1_900_000_000),
            state: "active", dateConfirmed: true)])
        try await database.saveMatter(draft)
        try await database.setActionState(id: "action", state: "done")
        let done = try await database.action(id: "action")
        XCTAssertEqual(done?.state, "done")
        var edited = draft
        edited.title = "编辑已完成订单"
        edited.actions[0].state = "done"
        edited.actions[0].dateConfirmed = false
        let editedDone = try await database.saveMatter(edited).first
        XCTAssertEqual(editedDone?.state, "done")
        XCTAssertNil(editedDone?.remindAt)
        try await database.setActionState(id: "action", state: "cancelled")
        let cancelled = try await database.action(id: "action")
        XCTAssertEqual(cancelled?.state, "cancelled")
        XCTAssertEqual(cancelled?.id, "action")
        edited.actions[0].state = "cancelled"
        let editedCancelled = try await database.saveMatter(edited).first
        XCTAssertEqual(editedCancelled?.state, "cancelled")
        XCTAssertNil(editedCancelled?.remindAt)

        let unknown = MatterDraft(id: "unknown", title: "日期未知", actions: [ActionDraft(id: "unknown-action", title: "补充日期")])
        try await database.saveMatter(unknown)
        try await database.setActionState(id: "unknown-action", state: "active")
        let stillUnknown = try await database.action(id: "unknown-action")
        XCTAssertEqual(stillUnknown?.state, "needs_date")
        XCTAssertNil(stillUnknown?.remindAt)
    }

    func testInvalidDatesAndBlankTitleCannotAlterSavedOrderAndFailedLinksRollBack() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try LibraryDatabase(path: root.appendingPathComponent("library.sqlite").path)
        let item = try await evidence(database: database, root: root)
        let fact = FactDraft(id: "date", key: "purchaseDate", valueText: "2024-02-29", valueType: "date", state: "confirmed")
        let original = MatterDraft(id: "order", title: "保存前的标题", itemIDs: [item.id], facts: [fact],
            actions: [ActionDraft(id: "stable", title: "已确认提醒", remindAt: Date(timeIntervalSince1970: 1_900_000_000),
                                state: "active", dateConfirmed: true)])
        let initialAction = try await database.saveMatter(original).first
        let initialMatter = try await database.matter(id: "order")
        let initialFacts = try await database.facts(matterID: "order")

        for invalidDate in ["2026-02-29", "2026-02-30", "2026-13-01", "2026-2-01", "不是日期"] {
            var invalid = original
            invalid.title = "不应写入的标题"
            invalid.facts[0].valueText = invalidDate
            await expectSaveFailure(invalid, database: database)
        }
        var blank = original
        blank.title = " \n\t"
        await expectSaveFailure(blank, database: database)

        // This fails inside the transaction, after updating the matter and deleting its links.
        var missingLink = original
        missingLink.title = "不能留下半份编辑"
        missingLink.itemIDs = ["not-an-indexed-item"]
        await expectSaveFailure(missingLink, database: database)

        // A fact source foreign-key failure also rolls back replaced facts and edited title.
        var missingSource = original
        missingSource.title = "同样不能留下半份编辑"
        missingSource.facts[0].sourceItemID = "not-an-indexed-item"
        await expectSaveFailure(missingSource, database: database)

        let savedMatter = try await database.matter(id: "order")
        let savedFacts = try await database.facts(matterID: "order")
        let savedLinks = try await database.files(FileQuery(matterID: "order"))
        let savedAction = try await database.action(id: "stable")
        XCTAssertEqual(savedMatter, initialMatter)
        XCTAssertEqual(savedFacts, initialFacts)
        XCTAssertEqual(savedLinks.files.map(\.id), [item.id])
        XCTAssertEqual(savedAction, initialAction)
    }

    func testManualOrderNeedsNoEvidenceAndEmptyFactsAreNotSaved() async throws {
        let database = try LibraryDatabase(path: ":memory:")
        let draft = MatterDraft(id: "manual", title: "手动录入订单", facts: [
            FactDraft(key: "merchant", valueText: "手填商家", state: "confirmed"),
            FactDraft(key: "purchaseDate", valueText: " \n", valueType: "date"),
            FactDraft()
        ])
        let action = try await database.saveMatter(draft).first
        let saved = try await database.matter(id: "manual")
        let facts = try await database.facts(matterID: "manual")
        let files = try await database.files(FileQuery(matterID: "manual"))
        XCTAssertNil(action)
        XCTAssertEqual(saved?.itemCount, 0)
        XCTAssertEqual(files.total, 0)
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts.first?.valueText, "手填商家")
        XCTAssertEqual(facts.first?.origin, "user")
        XCTAssertEqual(facts.first?.state, "confirmed")
    }
    func testMultipleActionsRemainIndependentAcrossEditsAndRestart() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("multi.sqlite").path
        let database = try LibraryDatabase(path: path)
        let item = try await evidence(database: database, root: root)
        let time = Date(timeIntervalSince1970: 1_900_000_000)
        var draft = MatterDraft(id: "computer", title: "我的电脑", itemIDs: [item.id], actions: [
            ActionDraft(id: "return", title: "检查退货", remindAt: time, state: "active", dateConfirmed: true),
            ActionDraft(id: "warranty", title: "检查保修", remindAt: time.addingTimeInterval(3600), state: "active", dateConfirmed: true),
            ActionDraft(id: "care", title: "检查 AppleCare")
        ])
        try await database.saveMatter(draft)
        let originalB = try await database.action(id: "warranty")
        let before = try await database.actions(matterID: draft.id)
        XCTAssertEqual(before.count, 3)
        draft.actions[0].remindAt = time.addingTimeInterval(600)
        draft.actions = [draft.actions[0]]
        try await database.saveMatter(draft)
        let unchangedB = try await database.action(id: "warranty")
        XCTAssertEqual(unchangedB, originalB)
        try await database.setActionState(id: "return", state: "done")
        let third = ActionDraft(id: "care", title: "检查 AppleCare", remindAt: time.addingTimeInterval(7200), state: "active", dateConfirmed: true)
        try await database.saveAction(third, matterID: draft.id)
        draft.actions = []
        draft.title = "我的电脑（已校对）"
        draft.facts = [FactDraft(key: "product", valueText: "合成电脑", state: "confirmed")]
        try await database.saveMatter(draft)
        let reopened = try LibraryDatabase(path: path)
        let all = try await reopened.actions(matterID: draft.id)
        XCTAssertEqual(Set(all.map(\.id)), ["return", "warranty", "care"])
        XCTAssertEqual(all.first { $0.id == "return" }?.state, "done")
        XCTAssertEqual(all.first { $0.id == "warranty" }?.remindAt, originalB?.remindAt)
        XCTAssertEqual(all.first { $0.id == "warranty" }?.updatedAt, originalB?.updatedAt)
        XCTAssertEqual(all.first { $0.id == "care" }?.remindAt, third.remindAt)
        try await reopened.setActionState(id: "warranty", state: "cancelled")
        let remaining = try await reopened.action(id: "care")
        XCTAssertEqual(remaining?.state, "active")
        XCTAssertEqual(remaining?.remindAt, third.remindAt)
    }

    func testDuplicateAndForeignActionIDsRollBackWholeMatterEdit() async throws {
        let database = try LibraryDatabase(path: ":memory:")
        let a = ActionDraft(id: "a", title: "原行动")
        var draft = MatterDraft(id: "one", title: "原事务", actions: [a])
        try await database.saveMatter(draft)
        draft.title = "不应保存"
        draft.actions = [a, a]
        await expectSaveFailure(draft, database: database)
        let second = MatterDraft(id: "two", title: "其它事务", actions: [ActionDraft(id: "b", title: "其它行动")])
        try await database.saveMatter(second)
        draft.actions = [ActionDraft(id: "b", title: "不应挪用")]
        await expectSaveFailure(draft, database: database)
        let matter = try await database.matter(id: "one")
        let action = try await database.action(id: "a")
        let foreign = try await database.action(id: "b")
        XCTAssertEqual(matter?.title, "原事务")
        XCTAssertEqual(action?.title, "原行动")
        XCTAssertEqual(foreign?.matterID, "two")
    }

}
