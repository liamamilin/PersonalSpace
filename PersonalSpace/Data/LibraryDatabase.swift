import Foundation
import GRDB

final class LibraryDatabase: Sendable {
    let queue: any DatabaseWriter

    init(path: String) throws {
        if path == ":memory:" {
            queue = try DatabaseQueue(path: path)
        } else {
            var configuration = Configuration()
            configuration.maximumReaderCount = 4
            queue = try DatabasePool(path: path, configuration: configuration)
        }
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
        migrator.registerMigration("M4-explicit-document-text") { db in
            try db.execute(sql: """
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
        }
        migrator.registerMigration("M5-photos-sensitivity") { db in
            try db.execute(sql: """
                ALTER TABLE source ADD COLUMN kind TEXT NOT NULL DEFAULT 'folder';
                ALTER TABLE item ADD COLUMN kind TEXT NOT NULL DEFAULT 'file';
                ALTER TABLE item ADD COLUMN photoLocalIdentifier TEXT;
                ALTER TABLE item ADD COLUMN sensitivity TEXT NOT NULL DEFAULT 'normal'
                    CHECK(sensitivity IN ('normal', 'suspected', 'sensitive'));
                """)
            for row in try Row.fetchAll(db, sql: "SELECT id, name FROM item") {
                let name: String = row["name"]
                guard DocumentTextExtractor.isPotentiallySensitive(name: name) else { continue }
                let id: String = row["id"]
                try db.execute(sql: "UPDATE item SET sensitivity='suspected' WHERE id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM document_text WHERE itemID=?", arguments: [id])
            }
        }
        migrator.registerMigration("M7-quick-imports") { db in
            try db.execute(sql: "ALTER TABLE item ADD COLUMN importedFromPath TEXT")
        }
        migrator.registerMigration("M9.1-text-freshness") { db in
            try db.execute(sql: """
                ALTER TABLE item ADD COLUMN textNeedsRefresh BOOLEAN NOT NULL DEFAULT 0;
                UPDATE item SET textNeedsRefresh=1 WHERE kind='file' AND EXISTS (
                    SELECT 1 FROM document_text dt WHERE dt.itemID=item.id AND item.modifiedAt>dt.indexedAt);
                DELETE FROM document_text WHERE itemID IN (SELECT id FROM item WHERE textNeedsRefresh=1);
                """)
        }
        migrator.registerMigration("M10-restored-source-authorization") { db in
            try db.execute(sql: "ALTER TABLE source ADD COLUMN needsAuthorization BOOLEAN NOT NULL DEFAULT 0")
        }
        migrator.registerMigration("source-auto-update-pause") { db in
            try db.execute(sql: """
                ALTER TABLE source ADD COLUMN autoUpdatePaused BOOLEAN NOT NULL DEFAULT 0;
                UPDATE source SET autoUpdatePaused=1 WHERE kind='folder' AND lastError IS NOT NULL;
                """)
        }
        migrator.registerMigration("source-scan-outcomes") { db in
            try db.execute(sql: """
                ALTER TABLE source ADD COLUMN scanReportJSON TEXT;
                ALTER TABLE item ADD COLUMN accessError TEXT;
                """)
        }
        migrator.registerMigration("inbox-candidate-index") { db in
            try db.execute(sql: "CREATE INDEX item_inbox_candidates ON item(id) WHERE kind='imported'")
        }
        try migrator.migrate(queue)
    }

    static func applicationDatabase() throws -> LibraryDatabase {
        try LibraryDatabase(path: ActiveLibrary.application().current().databaseURL.path)
    }


    static let fileColumns = """
        i.id, i.sourceID, i.relativePath, i.name, i.typeIdentifier, i.bytes,
        i.modifiedAt, i.createdAt, (i.isAvailable AND s.isEnabled) AS isAvailable,
        i.managedCopyPath, i.managedSHA256, i.managedAt,
        i.kind AS itemKind, i.photoLocalIdentifier, i.sensitivity, i.importedFromPath, i.textNeedsRefresh,
        (SELECT dt.indexedAt FROM document_text dt WHERE dt.itemID=i.id) AS textIndexedAt,
        s.name AS sourceName, s.path AS sourcePath,
        CASE WHEN s.isEnabled=0 AND s.kind='photos' THEN COALESCE(s.lastError, '照片图库访问已关闭，请重新授权照片。')
             WHEN s.isEnabled=0 THEN '已停止管理此来源，请重新添加文件夹恢复原件访问。'
             ELSE COALESCE(i.accessError, s.lastError) END AS sourceError
        """

    static func escapedSearch(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

enum LibraryDataError: LocalizedError {
    case documentChanged
    case invalidObject, invalidManagedCopy, managedCopyNotSaved, invalidMatter, invalidAction
    case documentTextTooLong, emptyDocumentText, documentNotFound, sensitiveDocument
    case invalidFolderSource, invalidPhoto, invalidSensitivity
    case importedOnly, importedStillLinked

    var errorDescription: String? {
        switch self {
        case .documentChanged: "文件在识别期间已发生变化，请重新识别后保存正文。"
        case .invalidObject: "请填写对象名称，并选择设备或其它类型。"
        case .invalidManagedCopy: "托管副本路径或校验信息无效。"
        case .managedCopyNotSaved: "资料不存在或已有托管副本，本次副本未保存。"
        case .invalidMatter: "请填写事务标题，并检查事实字段和来源信息。"
        case .invalidAction: "行动资料无效，请填写标题并确认具体提醒时间。"
        case .documentTextTooLong: "正文超过 200,000 字符，未保存索引。请拆分文档后重试。"
        case .emptyDocumentText: "没有可保存的正文。"
        case .documentNotFound: "资料记录已不可用，未保存正文索引。"
        case .sensitiveDocument: "文件名疑似包含密码、恢复码或账号资料，不能保存到普通正文索引。"
        case .invalidFolderSource: "此来源不是已授权文件夹，不能进行目录扫描。"
        case .invalidPhoto: "照片标识无效，未保存照片资料。"
        case .invalidSensitivity: "请选择普通、疑似敏感或敏感分类。"
        case .importedOnly: "只能移除通过快速收纳导入的文件。资料可能已被移除，请刷新列表。"
        case .importedStillLinked: "此文件仍关联个人对象、事务或事实出处。请先解除这些关联，再从 PersonalSpace 移除。"
        }
    }
}
