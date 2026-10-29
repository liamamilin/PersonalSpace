import CryptoKit
import GRDB
import XCTest
@testable import PersonalSpace

@MainActor
final class BackupTests: XCTestCase {
    private struct Fixture {
        let database: LibraryDatabase
        let vault: URL
        let itemID: String
        let copy: ManagedCopy
        let bytes: Data
        let original: URL
    }

    private func workspace() throws -> URL {
        // Canonical temporary roots avoid macOS temporary-directory aliases in path-safety checks.
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func fixture(in root: URL) async throws -> Fixture {
        let source = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let original = source.appendingPathComponent("订单.txt")
        let bytes = Data("合成测试凭证：100元，不含真实个人资料。".utf8)
        try bytes.write(to: original)
        try Data("外部源文件不应被复制到备份".utf8).write(to: source.appendingPathComponent("合同.txt"))
        let database = try LibraryDatabase(path: root.appendingPathComponent("live.sqlite").path)
        try await database.queue.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA journal_mode=WAL") }
        try await database.saveSource(id: "source", name: "测试来源", path: source.path, bookmark: Data([1]))
        try database.saveBatch([
            ScannedFile(relativePath: "订单.txt", name: "订单.txt", typeIdentifier: "public.plain-text", bytes: Int64(bytes.count)),
            ScannedFile(relativePath: "合同.txt", name: "合同.txt", typeIdentifier: "public.plain-text", bytes: 20)
        ], sourceID: "source", scanID: "seed")
        let indexed = try await database.files(FileQuery())
        let item = try XCTUnwrap(indexed.files.first { $0.name == "订单.txt" })
        let vault = root.appendingPathComponent("LiveVault", isDirectory: true)
        let store = ManagedFileStore(root: vault)
        let copy = try store.copy(sourceURL: original)
        try await database.saveManagedCopy(itemID: item.id, relativePath: copy.relativePath, sha256: copy.sha256)
        // A physical but unreferenced copy must not enter the exported snapshot.
        _ = try store.copy(sourceURL: original)
        try await database.saveObject(id: "computer", name: "测试电脑", kind: "device", notes: "备份关系")
        try await database.linkItems(indexed.files.map(\.id), to: "computer")
        try await database.saveMatter(MatterDraft(id: "order", title: "测试订单", objectID: "computer",
            itemIDs: [item.id], facts: [FactDraft(key: "merchant", valueText: "合成商家", sourceItemID: item.id)]))
        try await database.saveDocumentText(itemID: item.id, text: "backuptestnebula 合成正文")
        try await database.savePhotos([ScannedPhoto(localIdentifier: "synthetic-photo-id", name: "合成照片")])
        return Fixture(database: database, vault: vault, itemID: item.id, copy: copy, bytes: bytes, original: original)
    }

    private func expectFailure(_ operation: () async throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("Invalid backup operation unexpectedly succeeded", file: file, line: line)
        } catch { }
    }

    private func writeManifest(_ manifest: BackupManifest, into directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
    }

    func testDirectValidationDoesNotCreateCopiesOrChangeBackup() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await fixture(in: root)
        let backup = root.appendingPathComponent("Backup")
        let manifest = try await LibraryBackup.export(database: fixture.database, vaultRoot: fixture.vault, to: backup)
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        for _ in 0..<2 {
            let summary = try await LibraryBackup.inspect(at: backup)
            XCTAssertEqual(summary.managedCount, 1)
            XCTAssertEqual(summary.matterCount, 1)
            XCTAssertEqual(summary.manifest, manifest)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), before)
        let verified = try await LibraryBackup.verify(at: backup)
        XCTAssertEqual(verified, manifest)
    }

    func testTemporaryPreviewCleanupNeverRemovesBackupOrFormalLibrary() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await fixture(in: root)
        let backup = root.appendingPathComponent("Backup")
        let manifest = try await LibraryBackup.export(database: fixture.database, vaultRoot: fixture.vault, to: backup)
        let preview = try await LibraryBackup.makePreview(from: backup)
        defer { try? LibraryBackup.removePreview(at: preview) }
        let previewStore = ManagedFileStore(root: preview.appendingPathComponent("Vault"))
        XCTAssertEqual(try Data(contentsOf: previewStore.url(for: fixture.copy.relativePath)), fixture.bytes)
        try LibraryBackup.removePreview(at: preview)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.path))
        try LibraryBackup.removePreview(at: preview) // Dismiss/quit cleanup can coincide.
        XCTAssertThrowsError(try LibraryBackup.removePreview(at: backup))
        let formal = root.appendingPathComponent("FormalLibrary")
        _ = try await LibraryBackup.restore(from: backup, to: formal)
        XCTAssertThrowsError(try LibraryBackup.removePreview(at: formal))
        XCTAssertTrue(FileManager.default.fileExists(atPath: formal.appendingPathComponent("library.sqlite").path))
        let verified = try await LibraryBackup.verify(at: backup)
        XCTAssertEqual(verified, manifest)
        XCTAssertEqual(try Data(contentsOf: fixture.original), fixture.bytes)
    }

    func testWALDatabaseAndOnlyReferencedVaultCopyExportVerifyAndRestoreIntoNewLibrary() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await fixture(in: root)
        let backup = root.appendingPathComponent("Backup")
        let manifest = try await LibraryBackup.export(database: fixture.database, vaultRoot: fixture.vault, to: backup)
        XCTAssertEqual(manifest.formatVersion, 1)
        XCTAssertEqual(Set(manifest.files.map(\.path)), ["library.sqlite", "Vault/" + fixture.copy.relativePath])
        let archive = try XCTUnwrap(manifest.files.first { $0.path.hasPrefix("Vault/") })
        XCTAssertEqual(archive.sha256, fixture.copy.sha256)
        XCTAssertEqual(archive.bytes, Int64(fixture.bytes.count))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.appendingPathComponent("Source").path))
        let verified = try await LibraryBackup.verify(at: backup)
        XCTAssertEqual(verified, manifest)

        let restoredRoot = root.appendingPathComponent("Restored")
        let restoredManifest = try await LibraryBackup.restore(from: backup, to: restoredRoot)
        XCTAssertEqual(restoredManifest, manifest)
        let restored = try LibraryDatabase(path: restoredRoot.appendingPathComponent("library.sqlite").path)
        let objects = try await restored.objects()
        let linked = try await restored.files(FileQuery(objectID: "computer"))
        let matters = try await restored.matters()
        let facts = try await restored.facts(matterID: "order")
        let text = try await restored.documentText(itemID: fixture.itemID)
        let photo = try await restored.files(FileQuery(sourceID: "photos"))
        XCTAssertEqual(objects.first?.itemCount, 2)
        XCTAssertEqual(Set(linked.files.map(\.name)), ["订单.txt", "合同.txt"])
        XCTAssertEqual(matters.first?.objectID, "computer")
        XCTAssertEqual(facts.first?.valueText, "合成商家")
        XCTAssertEqual(text, "backuptestnebula 合成正文")
        XCTAssertEqual(photo.files.first?.photoLocalIdentifier, "synthetic-photo-id")
        let restoredFile = try await restored.file(id: fixture.itemID)
        XCTAssertEqual(restoredFile?.managedSHA256, fixture.copy.sha256)
        let store = ManagedFileStore(root: restoredRoot.appendingPathComponent("Vault"))
        XCTAssertEqual(try Data(contentsOf: store.url(for: fixture.copy.relativePath)), fixture.bytes)
        XCTAssertEqual(try Data(contentsOf: fixture.original), fixture.bytes)
    }

    func testDamagedDatabaseNeverCreatesRestoreTargetOrOverwritesExistingData() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await fixture(in: root)
        let backup = root.appendingPathComponent("Backup")
        _ = try await LibraryBackup.export(database: fixture.database, vaultRoot: fixture.vault, to: backup)
        try Data("damaged sqlite file".utf8).write(to: backup.appendingPathComponent("library.sqlite"))
        let existing = root.appendingPathComponent("Existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let sentinel = existing.appendingPathComponent("keep.txt")
        let sentinelBytes = Data("Existing data must remain unchanged".utf8)
        try sentinelBytes.write(to: sentinel)
        await expectFailure { _ = try await LibraryBackup.restore(from: backup, to: existing) }
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
        let absent = root.appendingPathComponent("MustNotExist")
        await expectFailure { _ = try await LibraryBackup.restore(from: backup, to: absent) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
        let activeObjects = try await fixture.database.objects()
        XCTAssertEqual(activeObjects.first?.name, "测试电脑")
        XCTAssertEqual(try Data(contentsOf: fixture.original), fixture.bytes)
    }

    func testMissingAndModifiedVaultFilesAreRejectedBeforeRestore() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await fixture(in: root)
        for scenario in ["missing", "modified"] {
            let backup = root.appendingPathComponent(scenario)
            _ = try await LibraryBackup.export(database: fixture.database, vaultRoot: fixture.vault, to: backup)
            let archived = backup.appendingPathComponent("Vault/" + fixture.copy.relativePath)
            if scenario == "missing" { try FileManager.default.removeItem(at: archived) }
            else { try Data("tampered".utf8).write(to: archived) }
            let target = root.appendingPathComponent("Restore-" + scenario)
            await expectFailure { _ = try await LibraryBackup.restore(from: backup, to: target) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
    }

    func testDuplicateExtraAndTraversalManifestPathsAreRejected() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await fixture(in: root)
        let outside = root.appendingPathComponent("outside.txt")
        let bytes = Data("outside unchanged".utf8)
        try bytes.write(to: outside)
        for scenario in ["duplicate", "extra-file", "extra-listed", "traversal"] {
            let backup = root.appendingPathComponent(scenario)
            let original = try await LibraryBackup.export(database: fixture.database, vaultRoot: fixture.vault, to: backup)
            var files = original.files
            switch scenario {
            case "duplicate": files.append(files[0])
            case "extra-file": try bytes.write(to: backup.appendingPathComponent("unlisted.txt"))
            case "extra-listed":
                try bytes.write(to: backup.appendingPathComponent("Vault/extra.txt"))
                files.append(BackupFileEntry(path: "Vault/extra.txt",
                    sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), bytes: Int64(bytes.count)))
            default: files.append(BackupFileEntry(path: "../outside.txt", sha256: String(repeating: "0", count: 64), bytes: 0))
            }
            try writeManifest(BackupManifest(formatVersion: 1, createdAt: original.createdAt, files: files), into: backup)
            await expectFailure { _ = try await LibraryBackup.verify(at: backup) }
        }
        XCTAssertEqual(try Data(contentsOf: outside), bytes)
    }

    func testSourceVaultDamageAbortsExportAndCleansOnlyNewTarget() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await fixture(in: root)
        let archived = try ManagedFileStore(root: fixture.vault).url(for: fixture.copy.relativePath)
        try Data("source archive changed".utf8).write(to: archived)
        let target = root.appendingPathComponent("FailedExport")
        await expectFailure {
            _ = try await LibraryBackup.export(database: fixture.database, vaultRoot: fixture.vault, to: target)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.vault.path))
        XCTAssertEqual(try Data(contentsOf: fixture.original), fixture.bytes)
        let existing = root.appendingPathComponent("Existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        await expectFailure {
            _ = try await LibraryBackup.export(database: fixture.database, vaultRoot: fixture.vault, to: existing)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path))
    }

    func testSymlinkSourcesBackupsAndDestinationParentsAreRejected() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await fixture(in: root)
        let backup = root.appendingPathComponent("Backup")
        _ = try await LibraryBackup.export(database: fixture.database, vaultRoot: fixture.vault, to: backup)
        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let destinationLink = root.appendingPathComponent("LinkedDestination")
        try FileManager.default.createSymbolicLink(at: destinationLink, withDestinationURL: outside)
        await expectFailure { _ = try await LibraryBackup.restore(from: backup, to: destinationLink.appendingPathComponent("New")) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        let linkedBackup = root.appendingPathComponent("LinkedBackup")
        try FileManager.default.createSymbolicLink(at: linkedBackup, withDestinationURL: backup)
        await expectFailure { _ = try await LibraryBackup.verify(at: linkedBackup) }

        let exportedArchive = backup.appendingPathComponent("Vault/" + fixture.copy.relativePath)
        try FileManager.default.removeItem(at: exportedArchive)
        try FileManager.default.createSymbolicLink(at: exportedArchive, withDestinationURL: fixture.original)
        await expectFailure { _ = try await LibraryBackup.verify(at: backup) }
        let sourceArchive = try ManagedFileStore(root: fixture.vault).url(for: fixture.copy.relativePath)
        try FileManager.default.removeItem(at: sourceArchive)
        try FileManager.default.createSymbolicLink(at: sourceArchive, withDestinationURL: fixture.original)
        let failedExport = root.appendingPathComponent("SymlinkExport")
        await expectFailure {
            _ = try await LibraryBackup.export(database: fixture.database, vaultRoot: fixture.vault, to: failedExport)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedExport.path))
        XCTAssertEqual(try Data(contentsOf: fixture.original), fixture.bytes)
    }

    func testLibraryWithoutManagedFilesCanBeBackedUpBeforeVaultExists() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try LibraryDatabase(path: ":memory:")
        try await database.saveObject(id: "empty", name: "新设备", kind: "device", notes: "")
        let backup = root.appendingPathComponent("Backup")
        let manifest = try await LibraryBackup.export(database: database,
            vaultRoot: root.appendingPathComponent("VaultDoesNotExist"), to: backup)
        XCTAssertEqual(manifest.files.map(\.path), ["library.sqlite"])
        let restoredRoot = root.appendingPathComponent("Restored")
        _ = try await LibraryBackup.restore(from: backup, to: restoredRoot)
        let restored = try LibraryDatabase(path: restoredRoot.appendingPathComponent("library.sqlite").path)
        let objects = try await restored.objects()
        XCTAssertEqual(objects.first?.name, "新设备")
    }
}
