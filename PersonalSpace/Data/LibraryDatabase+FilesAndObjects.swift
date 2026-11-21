import Foundation
import GRDB

extension LibraryDatabase {
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
            if query.inboxOnly {
                conditions.append("i.kind='imported'")
                conditions.append("NOT EXISTS (SELECT 1 FROM object_item oi WHERE oi.itemID=i.id)")
                conditions.append("NOT EXISTS (SELECT 1 FROM matter_item mi WHERE mi.itemID=i.id)")
            }
            if let sourceID = query.sourceID {
                conditions.append("i.sourceID = ?")
                arguments += [sourceID]
            }
            let words = query.search.split(whereSeparator: \.isWhitespace).map(String.init)
            for word in words {
                let escaped = Self.escapedSearch(word)
                var matches = ["i.name LIKE ? ESCAPE '\\'", "i.relativePath LIKE ? ESCAPE '\\'",
                    "s.name LIKE ? ESCAPE '\\'", "i.importedFromPath LIKE ? ESCAPE '\\'"]
                arguments += ["%\(escaped)%", "%\(escaped)%", "%\(escaped)%", "%\(escaped)%"]
                if query.searchBody {
                    if word.count < 3 {
                        // Trigram cannot match 1–2 characters; keep short Chinese queries useful.
                        matches.append("(i.sensitivity='normal' AND (i.kind='imported' OR (i.isAvailable=1 AND i.accessError IS NULL AND s.isEnabled=1 AND s.lastError IS NULL)) AND EXISTS (SELECT 1 FROM document_text dt WHERE dt.itemID=i.id AND dt.bodyText LIKE ? ESCAPE '\\'))")
                        arguments += ["%\(escaped)%"]
                    } else {
                        matches.append("""
                            (i.sensitivity='normal' AND (i.kind='imported' OR (i.isAvailable=1 AND i.accessError IS NULL AND s.isEnabled=1 AND s.lastError IS NULL)) AND i.id IN (SELECT dt.itemID FROM document_text dt
                                JOIN document_text_fts ON document_text_fts.rowid=dt.rowid
                                WHERE document_text_fts MATCH ?))
                            """)
                        // Quote the entire token so user text is never treated as FTS operators.
                        arguments += ["\"" + word.replacingOccurrences(of: "\"", with: "\"\"") + "\""]
                    }
                }
                conditions.append("(" + matches.joined(separator: " OR ") + ")")
            }
            let joinedConditions = " JOIN source s ON s.id=i.sourceID WHERE " + conditions.joined(separator: " AND ")
            let from = "FROM item i" + joinedConditions
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) " + from, arguments: arguments) ?? 0
            guard total > 0, query.limit != 0 else { return ([], total) }
            // A sparse global search gains nothing from walking the name index to stop
            // early: every row must be visited, with a table lookup for each name.
            // Filter sequentially and sort the few matches. Keep indexes for scoped
            // queries and searches that can stop after filling a page.
            let sparseGlobalSearch = !words.isEmpty && query.sort == .name && total <= query.limit
                && query.sourceID == nil && query.objectID == nil && query.matterID == nil
                && !query.inboxOnly && !query.managedOnly
            let resultsFrom = sparseGlobalSearch ? "FROM item i NOT INDEXED" + joinedConditions : from
            let files = try LibraryFile.fetchAll(db, sql: """
                SELECT \(Self.fileColumns)
                \(resultsFrom) ORDER BY \(query.sort.sql) \(query.ascending ? "ASC" : "DESC"), i.id LIMIT ? OFFSET ?
                """, arguments: arguments + [query.limit, max(0, query.offset)])
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

    // The original path is display/search metadata only. No source bookmark or access is retained.
    func saveImportedFile(metadata: ScannedFile, copy: ManagedCopy, originalPath: String) async throws -> String {
        guard !metadata.name.isEmpty, metadata.bytes >= 0, !originalPath.isEmpty,
              ManagedFileStore.isValidRelativePath(copy.relativePath),
              copy.sha256.count == 64, copy.sha256.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            throw LibraryDataError.invalidManagedCopy
        }
        return try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO source(id, name, path, bookmark, isEnabled, kind)
                VALUES ('inbox', '快速收纳', 'inbox://imports', ?, 1, 'import')
                ON CONFLICT(id) DO UPDATE SET isEnabled=1
                """, arguments: [Data()])
            let id = UUID().uuidString
            let now = Date()
            let sensitivity = DocumentTextExtractor.isPotentiallySensitive(name: metadata.name) ? "suspected" : "normal"
            try db.execute(sql: """
                INSERT INTO item(id, sourceID, relativePath, name, typeIdentifier, bytes,
                    modifiedAt, createdAt, indexedAt, scanID, isAvailable, kind, sensitivity,
                    managedCopyPath, managedSHA256, managedAt, importedFromPath)
                VALUES (?, 'inbox', ?, ?, ?, ?, ?, ?, ?, 'import', 0, 'imported', ?, ?, ?, ?, ?)
                """, arguments: [id, copy.relativePath, metadata.name, metadata.typeIdentifier, metadata.bytes,
                    metadata.modifiedAt, metadata.createdAt, now, sensitivity,
                    copy.relativePath, copy.sha256.lowercased(), now, originalPath])
            return id
        }
    }

    func importedRemovalPath(itemID: String) async throws -> String {
        try await queue.read { db in try Self.importedRemovalPath(db, itemID: itemID) }
    }

    // Commit the record removal before any file is unlinked. A failed commit leaves the copy intact.
    func removeImportedFile(itemID: String) async throws -> String {
        try await queue.write { db in
            let path = try Self.importedRemovalPath(db, itemID: itemID)
            try db.execute(sql: "DELETE FROM item WHERE id=?", arguments: [itemID])
            return path
        }
    }

    private static func importedRemovalPath(_ db: Database, itemID: String) throws -> String {
        guard let row = try Row.fetchOne(db, sql: "SELECT kind, managedCopyPath FROM item WHERE id=?", arguments: [itemID]),
              row["kind"] as String == "imported" else { throw LibraryDataError.importedOnly }
        let linked = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM object_item WHERE itemID=?)
                OR EXISTS(SELECT 1 FROM matter_item WHERE itemID=?)
                OR EXISTS(SELECT 1 FROM fact WHERE sourceItemID=?)
            """, arguments: [itemID, itemID, itemID]) ?? false
        guard !linked else { throw LibraryDataError.importedStillLinked }
        guard let path: String = row["managedCopyPath"], ManagedFileStore.isValidRelativePath(path) else {
            throw LibraryDataError.invalidManagedCopy
        }
        return path
    }

    // Called only after the user explicitly allows indexing the selected document's text.
    func saveDocumentText(itemID: String, text: String, expectedFile: LibraryFile? = nil) async throws {
        guard text.count <= 200_000 else { throw LibraryDataError.documentTextTooLong }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibraryDataError.emptyDocumentText
        }
        try await queue.write { db in
            guard let sensitivity = try String.fetchOne(db, sql: "SELECT sensitivity FROM item WHERE id=?", arguments: [itemID]) else {
                throw LibraryDataError.documentNotFound
            }
            guard sensitivity == "normal" else {
                throw LibraryDataError.sensitiveDocument
            }
            if let expectedFile, !expectedFile.isImported {
                guard try Bool.fetchOne(db, sql: "SELECT i.bytes IS ? AND i.modifiedAt IS ? AND i.isAvailable=1 AND i.accessError IS NULL AND s.isEnabled=1 AND s.lastError IS NULL FROM item i JOIN source s ON s.id=i.sourceID WHERE i.id=?",
                    arguments: [expectedFile.bytes, expectedFile.modifiedAt, itemID]) == true else {
                    throw LibraryDataError.documentChanged
                }
            }
            try db.execute(sql: """
                INSERT INTO document_text(itemID, bodyText, indexedAt) VALUES (?, ?, ?)
                ON CONFLICT(itemID) DO UPDATE SET bodyText=excluded.bodyText, indexedAt=excluded.indexedAt
                """, arguments: [itemID, text, Date()])
            try db.execute(sql: "UPDATE item SET textNeedsRefresh=0 WHERE id=?", arguments: [itemID])
        }
    }

    func deleteDocumentText(itemID: String) async throws {
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM document_text WHERE itemID=?", arguments: [itemID])
            try db.execute(sql: "UPDATE item SET textNeedsRefresh=0 WHERE id=?", arguments: [itemID])
        }
    }

    func documentText(itemID: String) async throws -> String? {
        try await queue.read { db in
            try String.fetchOne(db, sql: """
                SELECT dt.bodyText FROM document_text dt JOIN item i ON i.id=dt.itemID
                WHERE dt.itemID=? AND i.sensitivity='normal'
                """, arguments: [itemID])
        }
    }
}
