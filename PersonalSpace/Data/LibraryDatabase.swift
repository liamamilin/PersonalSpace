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
                FROM source s ORDER BY s.name COLLATE NOCASE, s.id
                """)
        }
    }

    func saveSource(id: String, name: String, path: String, bookmark: Data) async throws {
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO source(id, name, path, bookmark) VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name=excluded.name, path=excluded.path,
                    bookmark=excluded.bookmark, lastError=NULL
                """, arguments: [id, name, path, bookmark])
        }
    }

    func removeSource(_ id: String) async throws {
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM source WHERE id = ?", arguments: [id])
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
            var conditions = ["1=1"]
            var arguments = StatementArguments()
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
                SELECT i.*, s.name AS sourceName, s.path AS sourcePath, s.lastError AS sourceError
                \(from) ORDER BY \(query.sort.sql) \(query.ascending ? "ASC" : "DESC"), i.id LIMIT ?
                """, arguments: arguments + [query.limit])
            return (files, total)
        }
    }
}
