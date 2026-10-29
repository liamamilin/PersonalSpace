import CryptoKit
import Foundation
import GRDB

struct BackupFileEntry: Codable, Sendable, Equatable {
    let path: String
    let sha256: String
    let bytes: Int64
}

struct BackupManifest: Codable, Sendable, Equatable {
    let formatVersion: Int
    let createdAt: Date
    let files: [BackupFileEntry]
}

struct BackupSummary: Sendable {
    let manifest: BackupManifest
    let itemCount: Int
    let matterCount: Int
    let managedCount: Int
}

struct BackupCandidate: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let bookmark: Data
    let summary: BackupSummary
}

struct LibraryBackup: Sendable {
    static func inspect(at directory: URL) async throws -> BackupSummary {
        try await Task.detached(priority: .utility) {
            let manifest = try verifyFiles(at: directory)
            var configuration = Configuration()
            configuration.readonly = true
            let snapshot = try DatabaseQueue(path: directory.appendingPathComponent("library.sqlite").path, configuration: configuration)
            defer { try? snapshot.close() }
            return try snapshot.read { db in
                BackupSummary(manifest: manifest,
                    itemCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item") ?? 0,
                    matterCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM matter") ?? 0,
                    managedCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE managedCopyPath IS NOT NULL") ?? 0)
            }
        }.value
    }

    static func validateForUse(database: LibraryDatabase, vaultRoot: URL) throws {
        try database.queue.read { db in
            guard try String.fetchOne(db, sql: "PRAGMA quick_check") == "ok",
                  try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else { throw BackupError.invalidDatabase }
            for table in ["item", "personal_object", "matter", "fact", "action"] {
                _ = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")
            }
        }
        let store = ManagedFileStore(root: vaultRoot)
        for (path, hash) in try managedReferences(in: database.queue) {
            try validateDirectory(vaultRoot)
            guard try entry(for: store.url(for: path), path: path).sha256 == hash else { throw BackupError.changedFile }
        }
    }
    static func export(database: LibraryDatabase, vaultRoot: URL, to destination: URL) async throws -> BackupManifest {
        let work = Task.detached(priority: .utility) {
            try exportFiles(database: database, vaultRoot: vaultRoot, to: destination)
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    static func verify(at directory: URL) async throws -> BackupManifest {
        let work = Task.detached(priority: .utility) { try verifyFiles(at: directory) }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    static func restore(from directory: URL, to destination: URL) async throws -> BackupManifest {
        let work = Task.detached(priority: .utility) {
            // Do not create or modify the destination before every source file has passed validation.
            let manifest = try verifyFiles(at: directory)
            let target = try createDestination(destination)
            var completed = false
            defer { if !completed { try? FileManager.default.removeItem(at: target) } }
            try FileManager.default.createDirectory(at: target.appendingPathComponent("Vault", isDirectory: true),
                                                    withIntermediateDirectories: false)
            for entry in manifest.files {
                try Task.checkCancellation()
                let source = try file(at: entry.path, in: directory)
                let copied = try copy(source, path: entry.path, into: target)
                guard copied == entry else { throw BackupError.changedFile }
            }
            let encoder = manifestEncoder()
            try encoder.encode(manifest).write(to: target.appendingPathComponent("manifest.json"), options: .atomic)
            let restored = try verifyFiles(at: target)
            completed = true
            return restored
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    private static func exportFiles(database: LibraryDatabase, vaultRoot: URL, to destination: URL) throws -> BackupManifest {
        try Task.checkCancellation()
        let target = try createDestination(destination)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: target) } }
        let databaseURL = target.appendingPathComponent("library.sqlite")
        let snapshot = try DatabaseQueue(path: databaseURL.path)
        let references: [String: String]
        do {
            // GRDB's official SQLite backup API takes a consistent database snapshot, including WAL data.
            try database.queue.backup(to: snapshot)
            try snapshot.writeWithoutTransaction { db in
                guard try String.fetchOne(db, sql: "PRAGMA journal_mode=DELETE")?.lowercased() == "delete" else {
                    throw BackupError.invalidDatabase
                }
            }
            references = try managedReferences(in: snapshot)
            try snapshot.close()
        } catch {
            try? snapshot.close()
            throw error
        }
        // Switching a backed-up WAL database to DELETE can leave an unused shared-memory file.
        // The connection is closed and DELETE was confirmed; remove only this new snapshot's sidecars.
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: databaseURL.path + suffix)
            if (try? FileManager.default.attributesOfItem(atPath: sidecar.path)) != nil {
                let values = try sidecar.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isSymbolicLink != true, values.isRegularFile == true,
                      suffix != "-wal" || values.fileSize == 0 else { throw BackupError.invalidDatabase }
                try FileManager.default.removeItem(at: sidecar)
            }
        }
        try FileManager.default.createDirectory(at: target.appendingPathComponent("Vault", isDirectory: true),
                                                withIntermediateDirectories: false)
        var files = [try entry(for: databaseURL, path: "library.sqlite")]
        let store = ManagedFileStore(root: vaultRoot)
        for (path, expectedHash) in references.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            try validateDirectory(vaultRoot)
            let source = try store.url(for: path)
            let copied = try copy(source, path: "Vault/" + path, into: target)
            guard copied.sha256 == expectedHash else { throw BackupError.changedFile }
            files.append(copied)
        }
        let manifest = BackupManifest(formatVersion: 1,
            createdAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)),
            files: files.sorted { $0.path < $1.path })
        try manifestEncoder().encode(manifest).write(to: target.appendingPathComponent("manifest.json"), options: .atomic)
        _ = try verifyFiles(at: target)
        completed = true
        return manifest
    }

    private static func verifyFiles(at directory: URL) throws -> BackupManifest {
        try Task.checkCancellation()
        try validateDirectory(directory)
        let manifestURL = try file(at: "manifest.json", in: directory)
        let values = try manifestURL.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? .max) <= 16_777_216 else { throw BackupError.invalidManifest }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: BackupManifest
        do { manifest = try decoder.decode(BackupManifest.self, from: Data(contentsOf: manifestURL)) }
        catch { throw BackupError.invalidManifest }
        guard manifest.formatVersion == 1, !manifest.files.isEmpty else { throw BackupError.invalidManifest }
        var expectedFiles: Set<String> = ["manifest.json"]
        var expectedDirectories: Set<String> = ["Vault"]
        for entry in manifest.files {
            guard validEntryPath(entry.path), validSHA256(entry.sha256), entry.bytes >= 0,
                  expectedFiles.insert(entry.path).inserted else { throw BackupError.invalidManifest }
            var parent = (entry.path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                expectedDirectories.insert(parent)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        guard expectedFiles.contains("library.sqlite") else { throw BackupError.invalidManifest }
        try validateLayout(directory, files: expectedFiles, directories: expectedDirectories)
        for expected in manifest.files {
            try Task.checkCancellation()
            let actual = try entry(for: file(at: expected.path, in: directory), path: expected.path)
            guard actual == expected else { throw BackupError.changedFile }
        }
        let databaseURL = try file(at: "library.sqlite", in: directory)
        var configuration = Configuration()
        configuration.readonly = true
        let snapshot = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        defer { try? snapshot.close() }
        let references: [String: String]
        do {
            references = try managedReferences(in: snapshot)
            try snapshot.read { db in
                guard try String.fetchOne(db, sql: "PRAGMA quick_check") == "ok",
                      try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else {
                    throw BackupError.invalidDatabase
                }
            }
        } catch { throw BackupError.invalidDatabase }
        let archivedEntries = manifest.files.filter { $0.path.hasPrefix("Vault/") }
        guard Set(archivedEntries.map { String($0.path.dropFirst(6)) }) == Set(references.keys) else {
            throw BackupError.invalidManifest
        }
        for archive in archivedEntries {
            guard references[String(archive.path.dropFirst(6))] == archive.sha256 else {
                throw BackupError.changedFile
            }
        }
        return manifest
    }

    private static func managedReferences(in snapshot: DatabaseQueue) throws -> [String: String] {
        try snapshot.read { db in
            var result: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT managedCopyPath, managedSHA256 FROM item
                WHERE managedCopyPath IS NOT NULL OR managedSHA256 IS NOT NULL
                """) {
                let path: String? = row["managedCopyPath"]
                let hash: String? = row["managedSHA256"]
                guard let path, let hash, ManagedFileStore.isValidRelativePath(path), validSHA256(hash),
                      result[path] == nil || result[path] == hash else { throw BackupError.invalidDatabase }
                result[path] = hash
            }
            return result
        }
    }

    private static func createDestination(_ destination: URL) throws -> URL {
        guard destination.isFileURL else { throw BackupError.invalidPath }
        let target = URL(fileURLWithPath: destination.path, isDirectory: true)
        try validateDirectory(target.deletingLastPathComponent())
        // attributesOfItem detects a dangling symlink too; fileExists alone does not.
        guard (try? FileManager.default.attributesOfItem(atPath: target.path)) == nil else {
            throw BackupError.destinationExists
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        return target
    }

    private static func copy(_ source: URL, path: String, into root: URL) throws -> BackupFileEntry {
        guard validEntryPath(path) else { throw BackupError.invalidPath }
        try validateDirectory(root)
        let target = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try validateDirectory(target.deletingLastPathComponent())
        try FileManager.default.copyItem(at: source, to: target)
        return try entry(for: file(at: path, in: root), path: path)
    }

    private static func validateLayout(_ root: URL, files: Set<String>, directories: Set<String>) throws {
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey],
            options: [], errorHandler: { _, _ in false }) else { throw BackupError.invalidPath }
        let prefix = root.path + "/"
        var actualFiles: Set<String> = []
        var actualDirectories: Set<String> = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard url.path.hasPrefix(prefix) else { throw BackupError.invalidPath }
            let path = String(url.path.dropFirst(prefix.count))
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            guard values.isSymbolicLink != true else { throw BackupError.invalidPath }
            if values.isDirectory == true { actualDirectories.insert(path) }
            else if values.isRegularFile == true { actualFiles.insert(path) }
            else { throw BackupError.invalidPath }
        }
        guard actualFiles == files, actualDirectories == directories else { throw BackupError.invalidManifest }
    }

    private static func file(at path: String, in root: URL) throws -> URL {
        guard ManagedFileStore.isValidRelativePath(path) else { throw BackupError.invalidPath }
        try validateDirectory(root)
        var current = URL(fileURLWithPath: root.path, isDirectory: true)
        let components = path.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component)
            let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            guard values.isSymbolicLink != true else { throw BackupError.invalidPath }
            guard index == components.count - 1 ? values.isRegularFile == true : values.isDirectory == true else {
                throw BackupError.invalidPath
            }
        }
        return current
    }

    private static func validateDirectory(_ directory: URL) throws {
        guard directory.isFileURL else { throw BackupError.invalidPath }
        // Validate ancestors too, so a replaced parent cannot redirect reads/writes outside the chosen tree.
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in directory.path.split(separator: "/") {
            guard component != ".", component != ".." else { throw BackupError.invalidPath }
            current.appendPathComponent(String(component), isDirectory: true)
            let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else { throw BackupError.invalidPath }
        }
    }

    private static func entry(for url: URL, path: String) throws -> BackupFileEntry {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var bytes: Int64 = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            bytes += Int64(chunk.count)
            hash.update(data: chunk)
        }
        return BackupFileEntry(path: path, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(), bytes: bytes)
    }

    private static func validEntryPath(_ path: String) -> Bool {
        ManagedFileStore.isValidRelativePath(path) && (path == "library.sqlite" || path.hasPrefix("Vault/"))
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && $0.isASCII && !$0.isUppercase }
    }

    private static func manifestEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private enum BackupError: LocalizedError {
    case invalidPath, destinationExists, invalidManifest, invalidDatabase, changedFile

    var errorDescription: String? {
        switch self {
        case .invalidPath: "备份位置无效，不能访问符号链接或所选目录外的位置。"
        case .destinationExists: "目标位置已存在。请选择一个尚不存在的新目录，已有数据不会被覆盖。"
        case .invalidManifest: "备份文件清单不完整、重复或含有额外路径，无法验证。"
        case .invalidDatabase: "备份数据库或托管文件引用无效，无法恢复。"
        case .changedFile: "备份文件大小或 SHA-256 校验不一致，可能已损坏或在复制时发生变化。"
        }
    }
}
