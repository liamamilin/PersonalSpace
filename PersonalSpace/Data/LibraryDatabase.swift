import Foundation
import GRDB

final class LibraryDatabase: Sendable {
    let queue: DatabaseQueue

    init(path: String) throws {
        queue = try DatabaseQueue(path: path)
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
        migrator.registerMigration("M3-orders-facts-actions") { db in
            try db.execute(sql: """
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
                """)
        }
        try migrator.migrate(queue)
    }

    static func applicationDatabase() throws -> LibraryDatabase {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("PersonalSpace", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try LibraryDatabase(path: directory.appendingPathComponent("Library.sqlite").path)
    }

    func sources() async throws -> [FolderSource] {
        try await queue.read { db in
            try FolderSource.fetchAll(db, sql: """
                SELECT s.*, (SELECT COUNT(*) FROM item i WHERE i.sourceID = s.id) AS fileCount
                FROM source s WHERE s.isEnabled=1 ORDER BY s.name COLLATE NOCASE, s.id
                """)
        }
    }

    // Include stopped sources so selecting the same folder restores its original item IDs.
    func findSource(path: String) async throws -> FolderSource? {
        try await queue.read { db in
            try FolderSource.fetchOne(db, sql: """
                SELECT s.*, (SELECT COUNT(*) FROM item i WHERE i.sourceID = s.id) AS fileCount
                FROM source s WHERE s.path=?
                """, arguments: [path])
        }
    }

    func saveSource(id: String, name: String, path: String, bookmark: Data) async throws {
        try await queue.write { db in
            let retainedID = try String.fetchOne(db, sql: "SELECT id FROM source WHERE path=?",
                                                arguments: [path]) ?? id
            try db.execute(sql: """
                INSERT INTO source(id, name, path, bookmark) VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name=excluded.name, path=excluded.path,
                    bookmark=excluded.bookmark, lastError=NULL, isEnabled=1
                """, arguments: [retainedID, name, path, bookmark])
        }
    }

    func removeSource(_ id: String) async throws {
        try await queue.write { db in
            try db.execute(sql: "UPDATE source SET isEnabled=0 WHERE id=?", arguments: [id])
            try db.execute(sql: "UPDATE item SET isAvailable=0 WHERE sourceID=?", arguments: [id])
        }
    }

    func setSourceError(_ id: String, message: String) async throws {
        try await queue.write { db in
            try db.execute(sql: "UPDATE source SET lastError = ? WHERE id = ?", arguments: [message, id])
        }
    }

    func saveBatch(_ files: [ScannedFile], sourceID: String, scanID: String) throws {
        try queue.write { db in
            for file in files {
                try db.execute(sql: """
                    INSERT INTO item(id, sourceID, relativePath, name, typeIdentifier, bytes,
                        modifiedAt, createdAt, indexedAt, scanID, isAvailable)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
                    ON CONFLICT(sourceID, relativePath) DO UPDATE SET name=excluded.name,
                        typeIdentifier=excluded.typeIdentifier, bytes=excluded.bytes,
                        modifiedAt=excluded.modifiedAt, createdAt=excluded.createdAt,
                        indexedAt=excluded.indexedAt, scanID=excluded.scanID, isAvailable=1
                    """, arguments: [UUID().uuidString, sourceID, file.relativePath, file.name,
                        file.typeIdentifier, file.bytes, file.modifiedAt, file.createdAt, Date(), scanID])
            }
        }
    }

    // Only a complete enumeration may mark old paths unavailable.
    func finishScan(sourceID: String, scanID: String) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE item SET isAvailable=0 WHERE sourceID=? AND scanID<>?",
                           arguments: [sourceID, scanID])
            try db.execute(sql: "UPDATE source SET lastScannedAt=?, lastError=NULL WHERE id=?",
                           arguments: [Date(), sourceID])
        }
    }

    func files(_ query: FileQuery) async throws -> (files: [LibraryFile], total: Int) {
        try await queue.read { db in
            var conditions: [String] = []
            var arguments = StatementArguments()
            if let objectID = query.objectID {
                conditions.append("EXISTS (SELECT 1 FROM object_item oi WHERE oi.itemID=i.id AND oi.objectID=?)")
                arguments += [objectID]
            }
            if let matterID = query.matterID {
                conditions.append("EXISTS (SELECT 1 FROM matter_item mi WHERE mi.itemID=i.id AND mi.matterID=?)")
                arguments += [matterID]
            }
            if query.objectID == nil, query.matterID == nil, !query.managedOnly {
                conditions.append("s.isEnabled=1")
            }
            if query.managedOnly {
                conditions.append("i.managedCopyPath IS NOT NULL")
            }
            if let sourceID = query.sourceID {
                conditions.append("i.sourceID = ?")
                arguments += [sourceID]
            }
            let words = query.search.split(whereSeparator: \.isWhitespace).map(String.init)
            for word in words {
                let escaped = word.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                conditions.append("(i.name LIKE ? ESCAPE '\\' OR i.relativePath LIKE ? ESCAPE '\\' OR s.name LIKE ? ESCAPE '\\')")
                arguments += ["%\(escaped)%", "%\(escaped)%", "%\(escaped)%"]
            }
            let from = "FROM item i JOIN source s ON s.id=i.sourceID WHERE " + conditions.joined(separator: " AND ")
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) " + from, arguments: arguments) ?? 0
            let files = try LibraryFile.fetchAll(db, sql: """
                SELECT \(Self.fileColumns)
                \(from) ORDER BY \(query.sort.sql) \(query.ascending ? "ASC" : "DESC"), i.id LIMIT ?
                """, arguments: arguments + [query.limit])
            return (files, total)
        }
    }

    func file(id: String) async throws -> LibraryFile? {
        try await queue.read { db in
            try LibraryFile.fetchOne(db, sql: """
                SELECT \(Self.fileColumns) FROM item i JOIN source s ON s.id=i.sourceID WHERE i.id=?
                """, arguments: [id])
        }
    }

    func objects(search: String = "") async throws -> [PersonalObject] {
        try await queue.read { db in
            var conditions = ["1=1"]
            var arguments = StatementArguments()
            for word in search.split(whereSeparator: \.isWhitespace).map(String.init) {
                let escaped = Self.escapedSearch(word)
                conditions.append("(o.name LIKE ? ESCAPE '\\' OR o.notes LIKE ? ESCAPE '\\')")
                arguments += ["%\(escaped)%", "%\(escaped)%"]
            }
            return try PersonalObject.fetchAll(db, sql: """
                SELECT o.*, (SELECT COUNT(*) FROM object_item oi WHERE oi.objectID=o.id) AS itemCount
                FROM personal_object o WHERE \(conditions.joined(separator: " AND "))
                ORDER BY o.name COLLATE NOCASE, o.id
                """, arguments: arguments)
        }
    }

    func saveObject(id: String, name: String, kind: String, notes: String) async throws {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, ["device", "other"].contains(kind) else {
            throw LibraryDataError.invalidObject
        }
        try await queue.write { db in
            let now = Date()
            try db.execute(sql: """
                INSERT INTO personal_object(id, name, kind, notes, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name=excluded.name, kind=excluded.kind,
                    notes=excluded.notes, updatedAt=excluded.updatedAt
                """, arguments: [id, cleanName, kind, notes, now, now])
        }
    }

    func deleteObject(_ id: String) async throws {
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM personal_object WHERE id=?", arguments: [id])
        }
    }

    func linkItems(_ itemIDs: [String], to objectID: String) async throws {
        try await queue.write { db in
            for itemID in Set(itemIDs) {
                try db.execute(sql: """
                    INSERT INTO object_item(objectID, itemID) VALUES (?, ?)
                    ON CONFLICT(objectID, itemID) DO NOTHING
                    """, arguments: [objectID, itemID])
            }
            try db.execute(sql: "UPDATE personal_object SET updatedAt=? WHERE id=?",
                           arguments: [Date(), objectID])
        }
    }

    func unlinkItem(_ itemID: String, from objectID: String) async throws {
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM object_item WHERE objectID=? AND itemID=?",
                           arguments: [objectID, itemID])
            try db.execute(sql: "UPDATE personal_object SET updatedAt=? WHERE id=?",
                           arguments: [Date(), objectID])
        }
    }

    func objectsForItem(_ itemID: String) async throws -> [PersonalObject] {
        try await queue.read { db in
            try PersonalObject.fetchAll(db, sql: """
                SELECT o.*, (SELECT COUNT(*) FROM object_item allLinks WHERE allLinks.objectID=o.id) AS itemCount
                FROM personal_object o JOIN object_item oi ON oi.objectID=o.id WHERE oi.itemID=?
                ORDER BY o.name COLLATE NOCASE, o.id
                """, arguments: [itemID])
        }
    }

    func saveManagedCopy(itemID: String, relativePath: String, sha256: String) async throws {
        guard ManagedFileStore.isValidRelativePath(relativePath),
              sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            throw LibraryDataError.invalidManagedCopy
        }
        try await queue.write { db in
            try db.execute(sql: """
                UPDATE item SET managedCopyPath=?, managedSHA256=?, managedAt=?
                WHERE id=? AND managedCopyPath IS NULL
                """, arguments: [relativePath, sha256.lowercased(), Date(), itemID])
            guard db.changesCount == 1 else { throw LibraryDataError.managedCopyNotSaved }
        }
    }

    func matters(search: String = "") async throws -> [MatterRecord] {
        try await queue.read { db in
            var conditions = ["1=1"]
            var arguments = StatementArguments()
            for word in search.split(whereSeparator: \.isWhitespace).map(String.init) {
                let escaped = Self.escapedSearch(word)
                conditions.append("(m.title LIKE ? ESCAPE '\\' OR m.notes LIKE ? ESCAPE '\\')")
                arguments += ["%\(escaped)%", "%\(escaped)%"]
            }
            return try MatterRecord.fetchAll(db, sql: """
                SELECT m.*, (SELECT COUNT(*) FROM matter_item mi WHERE mi.matterID=m.id) AS itemCount
                FROM matter m WHERE \(conditions.joined(separator: " AND "))
                ORDER BY m.updatedAt DESC, m.id
                """, arguments: arguments)
        }
    }

    func matter(id: String) async throws -> MatterRecord? {
        try await queue.read { db in
            try MatterRecord.fetchOne(db, sql: """
                SELECT m.*, (SELECT COUNT(*) FROM matter_item mi WHERE mi.matterID=m.id) AS itemCount
                FROM matter m WHERE m.id=?
                """, arguments: [id])
        }
    }

    func facts(matterID: String) async throws -> [FactRecord] {
        try await queue.read { db in
            try FactRecord.fetchAll(db, sql: "SELECT * FROM fact WHERE matterID=? ORDER BY rowid",
                                    arguments: [matterID])
        }
    }

    func actions(matterID: String? = nil) async throws -> [ActionRecord] {
        try await queue.read { db in
            let condition = matterID == nil ? "1=1" : "a.matterID=?"
            let arguments: StatementArguments = matterID.map { [$0] } ?? []
            return try ActionRecord.fetchAll(db, sql: """
                SELECT a.*, m.title AS matterTitle FROM action a LEFT JOIN matter m ON m.id=a.matterID
                WHERE \(condition)
                ORDER BY CASE a.state WHEN 'active' THEN 0 WHEN 'needs_date' THEN 1 ELSE 2 END,
                    a.remindAt IS NULL, a.remindAt, a.updatedAt DESC, a.id
                """, arguments: arguments)
        }
    }

    func action(id: String) async throws -> ActionRecord? {
        try await queue.read { db in
            try Self.fetchAction(db, id: id)
        }
    }

    // Saving the editor is atomic: failed links/facts cannot leave a half-saved order or reminder.
    // A nil action means the user disabled the order's action; its old rows remain cancelled.
    @discardableResult
    func saveMatter(_ draft: MatterDraft) async throws -> ActionRecord? {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let facts = draft.facts.compactMap { fact -> FactDraft? in
            var cleaned = fact
            cleaned.valueText = fact.valueText.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.valueText.isEmpty ? nil : cleaned
        }
        guard !draft.id.isEmpty, !title.isEmpty, draft.kind == "order",
              ["active", "completed"].contains(draft.status),
              facts.allSatisfy({ !$0.id.isEmpty && !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && ["text", "date", "amount"].contains($0.valueType)
                  && ["candidate", "confirmed"].contains($0.state)
                  && ["ocr", "model", "user"].contains($0.origin)
                  && ($0.valueType != "date" || Self.isValidCalendarDate($0.valueText)) }) else {
            throw LibraryDataError.invalidMatter
        }
        if let action = draft.action {
            guard !action.id.isEmpty, !action.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ["needs_date", "active", "done", "cancelled"].contains(action.state),
                  action.dueDate?.timeIntervalSince1970.isFinite != false,
                  action.remindAt?.timeIntervalSince1970.isFinite != false else {
                throw LibraryDataError.invalidAction
            }
        }
        return try await queue.write { db in
            let now = Date()
            try db.execute(sql: """
                INSERT INTO matter(id, kind, title, status, objectID, notes, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, title=excluded.title,
                    status=excluded.status, objectID=excluded.objectID, notes=excluded.notes,
                    updatedAt=excluded.updatedAt
                """, arguments: [draft.id, draft.kind, title, draft.status, draft.objectID, draft.notes, now, now])
            try db.execute(sql: "DELETE FROM matter_item WHERE matterID=?", arguments: [draft.id])
            for itemID in Set(draft.itemIDs) {
                try db.execute(sql: "INSERT INTO matter_item(matterID, itemID) VALUES (?, ?)",
                               arguments: [draft.id, itemID])
            }
            try db.execute(sql: "DELETE FROM fact WHERE matterID=?", arguments: [draft.id])
            for fact in facts {
                try db.execute(sql: """
                    INSERT INTO fact(id, matterID, key, valueText, valueType, state, sourceItemID, sourceExcerpt, origin)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [fact.id, draft.id, fact.key, fact.valueText, fact.valueType,
                        fact.state, fact.sourceItemID, fact.sourceExcerpt, fact.origin])
            }
            guard let action = draft.action else {
                try db.execute(sql: "UPDATE action SET state='cancelled', updatedAt=? WHERE matterID=?",
                               arguments: [now, draft.id])
                return nil
            }
            // The first action belongs to this editor even when an edit generated a fresh draft UUID.
            let stableID = try String.fetchOne(db, sql: """
                SELECT id FROM action WHERE matterID=? ORDER BY createdAt, id LIMIT 1
                """, arguments: [draft.id]) ?? action.id
            if let existing = try Row.fetchOne(db, sql: "SELECT matterID FROM action WHERE id=?", arguments: [stableID]) {
                let owner: String? = existing["matterID"]
                guard owner == draft.id else { throw LibraryDataError.invalidAction }
            }
            let state: String
            let reminder: Date?
            if ["done", "cancelled"].contains(action.state) {
                state = action.state
                reminder = nil
            } else if !action.dateConfirmed || action.remindAt == nil {
                state = "needs_date"
                reminder = nil
            } else {
                state = action.state == "needs_date" ? "active" : action.state
                reminder = action.remindAt
            }
            try db.execute(sql: """
                INSERT INTO action(id, matterID, title, dueDate, remindAt, state, dateConfirmed, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET title=excluded.title, dueDate=excluded.dueDate,
                    remindAt=excluded.remindAt, state=excluded.state, dateConfirmed=excluded.dateConfirmed,
                    updatedAt=excluded.updatedAt
                """, arguments: [stableID, draft.id, action.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    action.dueDate, reminder, state, action.dateConfirmed, now, now])
            return try Self.fetchAction(db, id: stableID)
        }
    }

    func setActionState(id: String, state: String) async throws {
        guard ["needs_date", "active", "done", "cancelled"].contains(state) else {
            throw LibraryDataError.invalidAction
        }
        try await queue.write { db in
            guard let action = try Self.fetchAction(db, id: id) else { throw LibraryDataError.invalidAction }
            let normalized = state == "active" && (!action.dateConfirmed || action.remindAt == nil)
                ? "needs_date" : state
            try db.execute(sql: "UPDATE action SET state=?, updatedAt=? WHERE id=?",
                           arguments: [normalized, Date(), id])
        }
    }

    private static func fetchAction(_ db: Database, id: String) throws -> ActionRecord? {
        try ActionRecord.fetchOne(db, sql: """
            SELECT a.*, m.title AS matterTitle FROM action a LEFT JOIN matter m ON m.id=a.matterID WHERE a.id=?
            """, arguments: [id])
    }

    private static func isValidCalendarDate(_ value: String) -> Bool {
        guard value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else {
            return false
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    private static let fileColumns = """
        i.id, i.sourceID, i.relativePath, i.name, i.typeIdentifier, i.bytes,
        i.modifiedAt, i.createdAt, (i.isAvailable AND s.isEnabled) AS isAvailable,
        i.managedCopyPath, i.managedSHA256, i.managedAt,
        s.name AS sourceName, s.path AS sourcePath,
        CASE WHEN s.isEnabled=0 THEN '已停止管理此来源，请重新添加文件夹恢复原件访问。'
             ELSE s.lastError END AS sourceError
        """

    private static func escapedSearch(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

private enum LibraryDataError: LocalizedError {
    case invalidObject, invalidManagedCopy, managedCopyNotSaved, invalidMatter, invalidAction

    var errorDescription: String? {
        switch self {
        case .invalidObject: "请填写对象名称，并选择设备或其它类型。"
        case .invalidManagedCopy: "托管副本路径或校验信息无效。"
        case .managedCopyNotSaved: "资料不存在或已有托管副本，本次副本未保存。"
        case .invalidMatter: "请填写订单标题，并检查事实字段和来源信息。"
        case .invalidAction: "行动资料无效，请填写标题并确认具体提醒时间。"
        }
    }
}
