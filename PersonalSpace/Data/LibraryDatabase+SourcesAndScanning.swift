import Foundation
import GRDB

extension LibraryDatabase {
    func prepareRestoredLibrary() async throws {
        try await queue.write { db in
            try db.execute(sql: """
                UPDATE source SET bookmark=X'', needsAuthorization=1, lastError='需要重新授权；可选择新电脑上的对应文件夹。' WHERE kind='folder';
                UPDATE item SET isAvailable=0 WHERE sourceID IN (SELECT id FROM source WHERE kind IN ('folder','photos'));
                UPDATE source SET isEnabled=0, lastError='请重新连接照片图库；旧设备的照片标识可能不可用。' WHERE kind='photos';
                """)
        }
    }

    func reauthorizeSource(id: String, name: String, path: String, bookmark: Data) async throws {
        try await queue.write { db in
            guard let source = try Row.fetchOne(db, sql: "SELECT path, needsAuthorization FROM source WHERE id=? AND kind='folder'", arguments: [id]),
                  (source["needsAuthorization"] as Bool) || (source["path"] as String) == path else {
                throw LibraryDataError.invalidFolderSource
            }
            try db.execute(sql: "UPDATE source SET name=?, path=?, bookmark=?, needsAuthorization=0, lastError=NULL, autoUpdatePaused=0, isEnabled=1 WHERE id=?",
                arguments: [name, path, bookmark, id])
        }
    }

    func sources() async throws -> [FolderSource] {
        try await queue.read { db in
            try FolderSource.fetchAll(db, sql: """
                SELECT s.*, (SELECT COUNT(*) FROM item i WHERE i.sourceID = s.id) AS fileCount
                FROM source s WHERE s.isEnabled=1 AND s.kind='folder' ORDER BY s.name COLLATE NOCASE, s.id
                """)
        }
    }

    // Include stopped sources so selecting the same folder restores its original item IDs.
    func findSource(path: String) async throws -> FolderSource? {
        try await queue.read { db in
            try FolderSource.fetchOne(db, sql: """
                SELECT s.*, (SELECT COUNT(*) FROM item i WHERE i.sourceID = s.id) AS fileCount
                FROM source s WHERE s.path=? AND s.kind='folder'
                """, arguments: [path])
        }
    }

    func saveSource(id: String, name: String, path: String, bookmark: Data) async throws {
        guard !["photos", "inbox"].contains(id),
              !["photos://system-library", "inbox://imports"].contains(path) else {
            throw LibraryDataError.invalidFolderSource
        }
        try await queue.write { db in
            let retainedID = try String.fetchOne(db, sql: "SELECT id FROM source WHERE path=? AND kind='folder'",
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

    func setSourceAutoUpdatePaused(_ id: String, paused: Bool) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE source SET autoUpdatePaused=? WHERE id=? AND kind='folder' AND isEnabled=1",
                arguments: [paused, id])
            guard db.changesCount == 1 else { throw LibraryDataError.invalidFolderSource }
        }
    }

    func setSourceError(_ id: String, message: String) async throws {
        try await queue.write { db in
            try db.execute(sql: "UPDATE source SET lastError = ? WHERE id = ?", arguments: [message, id])
        }
    }

    func saveBatch(_ files: [ScannedFile], sourceID: String, scanID: String) throws {
        try queue.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT kind='folder' FROM source WHERE id=?", arguments: [sourceID]) == true else {
                throw LibraryDataError.invalidFolderSource
            }
            guard !files.isEmpty else { return }
            let placeholders = Array(repeating: "?", count: files.count).joined(separator: ",")
            let existing = try Row.fetchAll(db, sql: """
                SELECT i.relativePath, i.name, i.typeIdentifier, i.bytes, i.modifiedAt,
                    i.createdAt, i.isAvailable, i.accessError,
                    EXISTS (SELECT 1 FROM document_text dt WHERE dt.itemID=i.id) AS hasBody
                FROM item i
                WHERE i.sourceID=? AND i.relativePath IN (\(placeholders))
                """, arguments: StatementArguments([sourceID] + files.map(\.relativePath)))
            let byPath = Dictionary(uniqueKeysWithValues: existing.map { ($0["relativePath"] as String, $0) })
            let indexedPaths = Set(existing.filter { $0["hasBody"] as Bool }.map { $0["relativePath"] as String })
            var unchanged: [String] = []
            var newFiles: [ScannedFile] = []
            let indexedAt = Date().databaseValue
            let insertSQL = """
                INSERT INTO item(id, sourceID, relativePath, name, typeIdentifier, bytes,
                    modifiedAt, createdAt, indexedAt, scanID, isAvailable, sensitivity)
                VALUES
                """
            let conflictSQL = """
                ON CONFLICT(sourceID, relativePath) DO UPDATE SET name=excluded.name,
                    typeIdentifier=excluded.typeIdentifier, bytes=excluded.bytes,
                    modifiedAt=excluded.modifiedAt, createdAt=excluded.createdAt,
                    indexedAt=excluded.indexedAt, scanID=excluded.scanID, isAvailable=1, accessError=NULL
                """
            let valueSQL = "(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)"
            let upsert = try db.cachedStatement(sql: insertSQL + valueSQL + conflictSQL)
            for file in files {
                if let previous = byPath[file.relativePath] {
                    let modified: DatabaseValue = previous["modifiedAt"]
                    let created: DatabaseValue = previous["createdAt"]
                    let accessError: String? = previous["accessError"]
                    if previous["name"] as String == file.name,
                       previous["typeIdentifier"] as String == file.typeIdentifier,
                       previous["bytes"] as Int64 == file.bytes,
                       previous["isAvailable"] as Bool, accessError == nil,
                       modified == (file.modifiedAt?.databaseValue ?? .null),
                       created == (file.createdAt?.databaseValue ?? .null) {
                        unchanged.append(file.relativePath)
                        continue
                    }
                } else {
                    newFiles.append(file)
                    continue
                }
                if indexedPaths.contains(file.relativePath) {
                    // Delete through document_text so its existing FTS trigger also
                    // removes the old tokens, atomically with this metadata update.
                    try db.execute(sql: """
                        UPDATE item SET textNeedsRefresh=1
                        WHERE sourceID=? AND relativePath=? AND (bytes IS NOT ? OR modifiedAt IS NOT ?)
                            AND EXISTS (SELECT 1 FROM document_text dt WHERE dt.itemID=item.id)
                        """, arguments: [sourceID, file.relativePath, file.bytes, file.modifiedAt])
                    try db.execute(sql: """
                        DELETE FROM document_text WHERE itemID IN (
                            SELECT id FROM item WHERE sourceID=? AND relativePath=? AND textNeedsRefresh=1)
                        """, arguments: [sourceID, file.relativePath])
                }
                let sensitivity = DocumentTextExtractor.isPotentiallySensitive(name: file.name) ? "suspected" : "normal"
                try upsert.execute(arguments: [UUID().uuidString, sourceID, file.relativePath, file.name,
                    file.typeIdentifier, file.bytes, file.modifiedAt, file.createdAt, indexedAt, scanID, sensitivity])
            }
            // New folders build their index in multi-row statements, not one
            // SQLite VM execution per file. 64 rows stays below 999 parameters.
            for start in stride(from: 0, to: newFiles.count, by: 64) {
                let group = newFiles[start..<min(start + 64, newFiles.count)]
                var arguments = StatementArguments()
                for file in group {
                    let sensitivity = DocumentTextExtractor.isPotentiallySensitive(name: file.name) ? "suspected" : "normal"
                    arguments += [UUID().uuidString, sourceID, file.relativePath, file.name,
                        file.typeIdentifier, file.bytes, file.modifiedAt, file.createdAt, indexedAt, scanID, sensitivity]
                }
                let sql = insertSQL + Array(repeating: valueSQL, count: group.count).joined(separator: ",") + conflictSQL
                try db.cachedStatement(sql: sql).execute(arguments: arguments)
            }
            if !unchanged.isEmpty {
                let seenPlaceholders = Array(repeating: "?", count: unchanged.count).joined(separator: ",")
                try db.execute(sql: "UPDATE item SET scanID=? WHERE sourceID=? AND relativePath IN (\(seenPlaceholders))",
                    arguments: StatementArguments([scanID, sourceID] + unchanged))
            }
        }
    }

    // Reconcile only the enumerated scope; retain records beneath explicitly unreadable paths.
    func finishScan(sourceID: String, scanID: String, scope: String? = nil, report: FolderScanReport? = nil) throws {
        try queue.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT kind='folder' FROM source WHERE id=?", arguments: [sourceID]) == true else {
                throw LibraryDataError.invalidFolderSource
            }
            if let report {
                for issue in report.unreadable {
                    guard !issue.path.isEmpty else { throw LibraryDataError.invalidFolderSource }
                    // The source/path index also makes this efficient for large libraries.
                    try db.execute(sql: """
                        UPDATE item SET scanID=?, accessError=? WHERE sourceID=? AND scanID<>?
                        AND (relativePath=? OR (relativePath>=? AND relativePath<?))
                        """, arguments: [scanID, issue.reason, sourceID, scanID, issue.path, issue.path + "/", issue.path + "0"])
                }
            }
            var sql = "UPDATE item SET isAvailable=0, accessError=NULL WHERE sourceID=? AND scanID<>?"
            var arguments: StatementArguments = [sourceID, scanID]
            if let scope {
                sql += " AND (relativePath=? OR (relativePath>=? AND relativePath<?))"
                arguments += [scope, scope + "/", scope + "0"]
            }
            try db.execute(sql: sql, arguments: arguments)
            if var report {
                report.issues.removeAll(where: \.disappeared)
                if let scope, let previousJSON = try String.fetchOne(db, sql: "SELECT scanReportJSON FROM source WHERE id=?", arguments: [sourceID]),
                   let data = previousJSON.data(using: .utf8), var previous = try? JSONDecoder().decode(FolderScanReport.self, from: data) {
                    previous.issues.removeAll { $0.path == scope || $0.path.hasPrefix(scope + "/") }
                    let existingPaths = Set(previous.issues.map(\.path))
                    previous.issues += report.issues.filter { !existingPaths.contains($0.path) }
                    report = previous
                }
                let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
                try db.execute(sql: "UPDATE source SET scanReportJSON=? WHERE id=?", arguments: [json, sourceID])
            }
            try db.execute(sql: "UPDATE source SET lastScannedAt=?, lastError=NULL WHERE id=?",
                           arguments: [Date(), sourceID])
        }
    }

    func savePhotos(_ photos: [ScannedPhoto]) async throws {
        guard photos.allSatisfy({ !$0.localIdentifier.isEmpty }) else { throw LibraryDataError.invalidPhoto }
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO source(id, name, path, bookmark, isEnabled, kind)
                VALUES ('photos', '照片', 'photos://system-library', ?, 1, 'photos')
                ON CONFLICT(id) DO UPDATE SET isEnabled=1, lastError=NULL
                """, arguments: [Data()])
            let now = Date()
            for photo in photos {
                let name = photo.name.isEmpty ? "照片" : photo.name
                let sensitivity = DocumentTextExtractor.isPotentiallySensitive(name: name) ? "suspected" : "normal"
                try db.execute(sql: """
                    INSERT INTO item(id, sourceID, relativePath, name, typeIdentifier, bytes,
                        createdAt, modifiedAt, indexedAt, scanID, isAvailable, kind, photoLocalIdentifier, sensitivity)
                    VALUES (?, 'photos', ?, ?, 'public.image', 0, ?, ?, ?, 'photos', 1, 'photo', ?, ?)
                    ON CONFLICT(sourceID, relativePath) DO UPDATE SET name=excluded.name,
                        createdAt=excluded.createdAt, modifiedAt=excluded.modifiedAt, indexedAt=excluded.indexedAt,
                        isAvailable=1, kind='photo', photoLocalIdentifier=excluded.photoLocalIdentifier
                    """, arguments: [UUID().uuidString, photo.localIdentifier, name,
                        photo.createdAt, photo.modifiedAt, now, photo.localIdentifier, sensitivity])
            }
        }
    }

    func setPhotosAccess(allowed: Bool, message: String? = nil) async throws {
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO source(id, name, path, bookmark, isEnabled, kind, lastError)
                VALUES ('photos', '照片', 'photos://system-library', ?, ?, 'photos', ?)
                ON CONFLICT(id) DO UPDATE SET isEnabled=excluded.isEnabled, lastError=excluded.lastError
                """, arguments: [Data(), allowed, message])
            if !allowed {
                try db.execute(sql: "UPDATE item SET isAvailable=0 WHERE sourceID='photos'")
            }
        }
    }

    func setSensitivity(itemID: String, state: String) async throws {
        guard ["normal", "suspected", "sensitive"].contains(state) else { throw LibraryDataError.invalidSensitivity }
        try await queue.write { db in
            try db.execute(sql: "UPDATE item SET sensitivity=? WHERE id=?", arguments: [state, itemID])
            guard db.changesCount == 1 else { throw LibraryDataError.documentNotFound }
            if state != "normal" {
                try db.execute(sql: "DELETE FROM document_text WHERE itemID=?", arguments: [itemID])
            }
        }
    }
}
