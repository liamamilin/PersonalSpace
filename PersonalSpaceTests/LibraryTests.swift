import XCTest
import GRDB
import Combine
import Darwin
@testable import PersonalSpace

private final class ReloadTraceGate: @unchecked Sendable {
    private let lock = NSLock()
    private let barrier = DispatchSemaphore(value: 0)
    private var didBlock = false
    private var waiting = false
    private var reads = 0

    var isWaiting: Bool { lock.withLock { waiting } }
    var searchReads: Int { lock.withLock { reads } }
    func release() { barrier.signal() }

    func observe(_ sql: String) {
        let block = lock.withLock {
            if sql.contains("SELECT COUNT(*) FROM item i"), sql.contains("i.name LIKE") { reads += 1 }
            if !didBlock, sql.contains("AS fileCount"), sql.contains("FROM source s") {
                didBlock = true; waiting = true
                return true
            }
            return false
        }
        if block { _ = barrier.wait(timeout: .now() + 5) }
    }
}

@MainActor
final class LibraryTests: XCTestCase {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func folder(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func source(_ id: String, url: URL, database: LibraryDatabase) async throws {
        try await database.saveSource(id: id, name: url.lastPathComponent, path: url.path, bookmark: Data([1]))
    }

    func testConcurrentReloadsCoalesceDatabaseWorkAndKeepSearchResults() async throws {
        let database = try LibraryDatabase(path: ":memory:")
        try await source("synthetic", url: URL(fileURLWithPath: "/synthetic"), database: database)
        try database.saveBatch([ScannedFile(relativePath: "match.txt", name: "match.txt",
            typeIdentifier: "public.plain-text", bytes: 1)], sourceID: "synthetic", scanID: "fixture")
        let gate = ReloadTraceGate()
        try await database.queue.write { db in
            db.trace { event in
                if case let .statement(statement) = event { gate.observe(statement.sql) }
            }
        }
        defer { gate.release() }
        let model = LibraryModel(database: database)
        model.search = "match"
        let first = Task { await model.reload() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !gate.isWaiting, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(gate.isWaiting)
        var callers: [Task<Void, Never>] = []
        for _ in 0..<30 {
            callers.append(Task { await model.reload() })
            await Task.yield()
        }
        gate.release()
        await first.value
        for caller in callers { await caller.value }
        XCTAssertEqual(model.files.map(\.name), ["match.txt"])
        XCTAssertEqual(model.total, 1)
        XCTAssertLessThanOrEqual(gate.searchReads, 2,
            "Concurrent view and file-event refreshes must share a read and at most one follow-up, not queue one query per event")
        XCTAssertFalse(model.isQueryLoading)
    }

    func testChangingSearchDuringSlowReadNeverPublishesPreviousQuery() async throws {
        let database = try LibraryDatabase(path: ":memory:")
        try await source("synthetic", url: URL(fileURLWithPath: "/synthetic"), database: database)
        try database.saveBatch(["first.txt", "second.txt"].map {
            ScannedFile(relativePath: $0, name: $0, typeIdentifier: "public.plain-text", bytes: 1)
        }, sourceID: "synthetic", scanID: "fixture")
        let gate = ReloadTraceGate()
        try await database.queue.write { db in
            db.trace { event in
                if case let .statement(statement) = event { gate.observe(statement.sql) }
            }
        }
        defer { gate.release() }
        let model = LibraryModel(database: database)
        model.search = "first"
        var publishedOldResults = false
        let observation = model.$files.sink { files in
            if files.contains(where: { $0.name == "first.txt" }) { publishedOldResults = true }
        }
        defer { observation.cancel() }
        let first = Task { await model.reload() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !gate.isWaiting, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(gate.isWaiting)
        model.search = "second"
        XCTAssertTrue(model.isQueryLoading, "An unfinished query must not be presented as zero results")
        let second = Task { await model.reload() }
        await Task.yield()
        first.cancel() // SwiftUI cancels the task for the old search.
        gate.release()
        await first.value
        await second.value
        XCTAssertFalse(publishedOldResults)
        XCTAssertEqual(model.files.map(\.name), ["second.txt"])
        XCTAssertFalse(model.isQueryLoading)
        model.search = "missing"
        XCTAssertTrue(model.isQueryLoading)
        await model.reload()
        XCTAssertFalse(model.isQueryLoading)
        XCTAssertTrue(model.files.isEmpty)
        XCTAssertEqual(model.total, 0)
    }

    func testSearchPublishesResultsBeforeContinuousRefreshRequestsBecomeQuiet() async throws {
        let database = try LibraryDatabase(path: ":memory:")
        try await source("synthetic", url: URL(fileURLWithPath: "/synthetic"), database: database)
        try database.saveBatch([ScannedFile(relativePath: "needle.txt", name: "needle.txt",
            typeIdentifier: "public.plain-text", bytes: 1)], sourceID: "synthetic", scanID: "fixture")
        try await database.queue.write { db in
            db.trace { event in
                if case let .statement(statement) = event,
                   statement.sql.contains("SELECT COUNT(*) FROM item i"), statement.sql.contains("i.name LIKE") {
                    // Emulate a slow large-library read while refreshes arrive faster.
                    Thread.sleep(forTimeInterval: 0.12)
                }
            }
        }
        let model = LibraryModel(database: database)
        model.search = "needle"
        var producerFinished = false
        let producer = Task {
            var readers: [Task<Void, Never>] = []
            for _ in 0..<100 {
                readers.append(Task { await model.reload() })
                try? await Task.sleep(for: .milliseconds(10))
            }
            producerFinished = true
            for reader in readers { await reader.value }
        }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(700))
        while model.files.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.files.map(\.name), ["needle.txt"])
        XCTAssertFalse(producerFinished, "Search must return while the update stream is still active")
        await producer.value
        XCTAssertFalse(model.isQueryLoading)
    }

    func testUnchangedRescanOnlyUpdatesSeenMarkerAndChangedFileStillRefreshes() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try folder("source", in: root)
        let file = folder.appendingPathComponent("receipt.txt")
        try Data("original".utf8).write(to: file)
        let database = try LibraryDatabase(path: ":memory:")
        try await source("source", url: folder, database: database)
        try FolderScanner.scan(root: folder, sourceID: "source", database: database)
        let sentinel = Date(timeIntervalSince1970: 1_000)
        let before = try await database.queue.write { db in
            try db.execute(sql: "UPDATE item SET indexedAt=?", arguments: [sentinel])
            let row = try Row.fetchOne(db, sql: "SELECT id, scanID FROM item")!
            return (id: row["id"] as String, scanID: row["scanID"] as String)
        }
        try FolderScanner.scan(root: folder, sourceID: "source", database: database)
        let unchanged = try await database.queue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM item")!
            return (id: row["id"] as String, scanID: row["scanID"] as String, indexedAt: row["indexedAt"] as Date)
        }
        XCTAssertEqual(unchanged.id, before.id)
        XCTAssertNotEqual(unchanged.scanID, before.scanID)
        XCTAssertEqual(unchanged.indexedAt, sentinel)
        try Data("changed and longer".utf8).write(to: file)
        try FolderScanner.scan(root: folder, sourceID: "source", database: database)
        let changed = try await database.queue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM item")!
            return (id: row["id"] as String, bytes: row["bytes"] as Int, indexedAt: row["indexedAt"] as Date)
        }
        XCTAssertEqual(changed.id, before.id)
        XCTAssertEqual(changed.bytes, 18)
        XCTAssertGreaterThan(changed.indexedAt, sentinel)
    }

    func testBulkScanCrossesBufferAndDatabaseBatchesWithoutLosingPathsOrDates() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try folder("A", in: root)
        let nested = try folder("子目录", in: a)
        var expected = Set<String>()
        // Long names force more than one native metadata buffer, and the
        // total crosses both the 512-file batch and 64-row INSERT boundaries.
        for index in 0..<1153 {
            let name = "\(index)-" + String(repeating: "x", count: 230) + ".txt"
            try Data().write(to: a.appendingPathComponent(name))
            expected.insert(name)
        }
        for name in ["NFC-caf\u{e9}.txt", "NFD-cafe\u{301}.txt", "中文照片.jpg", "没有扩展名"] {
            try Data([1, 2, 3]).write(to: nested.appendingPathComponent(name))
            expected.insert("子目录/" + name)
        }
        let dated = nested.appendingPathComponent("中文照片.jpg")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000.123456)],
                                              ofItemAtPath: dated.path)
        let actualDate = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: dated.path)[.modificationDate] as? Date)
        let database = try LibraryDatabase(path: ":memory:")
        try await source("a", url: a, database: database)
        let report = try FolderScanner.scan(root: a, sourceID: "a", database: database)
        let rows = try await database.files(FileQuery(sourceID: "a", limit: 2000)).files
        XCTAssertEqual(report.fileCount, expected.count)
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertEqual(Set(rows.map(\.relativePath)), expected)
        let image = try XCTUnwrap(rows.first { $0.name == "中文照片.jpg" })
        XCTAssertEqual(image.bytes, 3)
        XCTAssertEqual(image.typeIdentifier, "public.jpeg")
        XCTAssertEqual(try XCTUnwrap(image.modifiedAt).timeIntervalSince1970, actualDate.timeIntervalSince1970, accuracy: 0.001)
        let ids = Dictionary(uniqueKeysWithValues: rows.map { ($0.relativePath, $0.id) })
        try FolderScanner.scan(root: a, sourceID: "a", database: database)
        let again = try await database.files(FileQuery(sourceID: "a", limit: 2000)).files
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: again.map { ($0.relativePath, $0.id) }), ids)
        // Exercise the persistent readdir iterator across its own output-buffer
        // boundary even when the test volume supports getattrlistbulk.
        let fallback = try FolderScanner.scan(root: a, sourceID: "a", database: database, preferBulkMetadata: false)
        let fallbackRows = try await database.files(FileQuery(sourceID: "a", limit: 2000)).files
        XCTAssertEqual(fallback.fileCount, expected.count)
        XCTAssertTrue(fallback.issues.isEmpty)
        XCTAssertEqual(Set(fallbackRows.map(\.relativePath)), expected)
        XCTAssertTrue(fallbackRows.allSatisfy(\.isAvailable))
    }

    func testBulkScanRespectsBSDAndFinderHiddenFlags() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try folder("A", in: root)
        for name in ["visible.txt", ".dot.txt", "bsd.txt", "finder.txt"] {
            try Data([1]).write(to: a.appendingPathComponent(name))
        }
        XCTAssertEqual(chflags(a.appendingPathComponent("bsd.txt").path, UInt32(UF_HIDDEN)), 0)
        var finder = [UInt8](repeating: 0, count: 32)
        finder[8] = 0x40
        let result = finder.withUnsafeBytes { bytes in
            setxattr(a.appendingPathComponent("finder.txt").path, "com.apple.FinderInfo", bytes.baseAddress, bytes.count, 0, 0)
        }
        XCTAssertEqual(result, 0)
        let database = try LibraryDatabase(path: ":memory:")
        try await source("a", url: a, database: database)
        try FolderScanner.scan(root: a, sourceID: "a", database: database)
        let files = try await database.files(FileQuery(sourceID: "a")).files
        XCTAssertEqual(files.map(\.name), ["visible.txt"])
        try FolderScanner.scan(root: a, sourceID: "a", database: database, preferBulkMetadata: false)
        let fallback = try await database.files(FileQuery(sourceID: "a")).files
        XCTAssertEqual(fallback.map(\.name), ["visible.txt"])
        // A later visibility-only event must not add a Finder-hidden file.
        try FolderScanner.scan(root: a, sourceID: "a", database: database, scope: "finder.txt")
        let scoped = try await database.files(FileQuery(sourceID: "a")).files
        XCTAssertEqual(scoped.map(\.name), ["visible.txt"])
    }

    func testMixedBatchKeepsExistingIdentityBodyLinksAndSensitivity() async throws {
        let database = try LibraryDatabase(path: ":memory:")
        try await source("a", url: URL(fileURLWithPath: "/synthetic"), database: database)
        let ordinary = ScannedFile(relativePath: "ordinary.txt", name: "ordinary.txt", typeIdentifier: "public.plain-text", bytes: 4)
        var classified = ScannedFile(relativePath: "classified.txt", name: "classified.txt", typeIdentifier: "public.plain-text", bytes: 1)
        try database.saveBatch([ordinary, classified], sourceID: "a", scanID: "before")
        let old = try await database.files(FileQuery(sourceID: "a")).files
        let ordinaryID = try XCTUnwrap(old.first { $0.name == ordinary.name }?.id)
        let classifiedID = try XCTUnwrap(old.first { $0.name == classified.name }?.id)
        try await database.saveDocumentText(itemID: ordinaryID, text: "retained-nebula")
        try await database.setSensitivity(itemID: classifiedID, state: "sensitive")
        try await database.saveObject(id: "object", name: "保留关联", kind: "other", notes: "")
        try await database.linkItems([ordinaryID], to: "object")
        classified.bytes = 9
        let new = (0..<130).map { ScannedFile(relativePath: "new-\($0).txt", name: "new-\($0).txt", typeIdentifier: "public.plain-text", bytes: 1) }
        // Exercise multiple fresh INSERT groups alongside unchanged and changed rows.
        try database.saveBatch(new + [ordinary, classified, new[0]], sourceID: "a", scanID: "after")
        let rows = try await database.files(FileQuery(sourceID: "a", limit: 200)).files
        XCTAssertEqual(rows.count, 132)
        XCTAssertEqual(rows.first { $0.name == ordinary.name }?.id, ordinaryID)
        XCTAssertEqual(rows.first { $0.name == classified.name }?.id, classifiedID)
        XCTAssertEqual(rows.first { $0.name == classified.name }?.sensitivity, "sensitive")
        let body = try await database.files(FileQuery(search: "retained-nebula", searchBody: true))
        XCTAssertEqual(body.files.map(\.id), [ordinaryID])
        let linked = try await database.files(FileQuery(objectID: "object"))
        XCTAssertEqual(linked.files.map(\.id), [ordinaryID])
    }

    func testTwoSourcesSearchFilterAndPersistence() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try folder("A", in: root), b = try folder("B", in: root)
        try Data("synthetic order".utf8).write(to: a.appendingPathComponent("订单样例.pdf"))
        try Data("synthetic contract".utf8).write(to: b.appendingPathComponent("租赁合同.txt"))
        let path = root.appendingPathComponent("index.sqlite").path
        let database = try LibraryDatabase(path: path)
        try await source("a", url: a, database: database)
        try await source("b", url: b, database: database)
        try FolderScanner.scan(root: a, sourceID: "a", database: database)
        try FolderScanner.scan(root: b, sourceID: "b", database: database)
        let order = try await database.files(FileQuery(search: "订单"))
        let contract = try await database.files(FileQuery(search: "合同"))
        let wrongSource = try await database.files(FileQuery(search: "合同", sourceID: "a"))
        XCTAssertEqual(order.files.first?.sourceID, "a")
        XCTAssertEqual(contract.files.first?.sourceID, "b")
        XCTAssertEqual(wrongSource.total, 0)
        let reopened = try LibraryDatabase(path: path)
        let sources = try await reopened.sources()
        let persisted = try await reopened.files(FileQuery(search: "合同"))
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(persisted.total, 1)
        XCTAssertEqual(persisted.files.first?.id, contract.files.first?.id)
    }

    func testMovedFileRemainsUnavailableAndReturnsWithSameID() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try folder("A", in: root)
        let original = a.appendingPathComponent("合同.txt")
        let outside = root.appendingPathComponent("moved.txt")
        try Data("test".utf8).write(to: original)
        let database = try LibraryDatabase(path: ":memory:")
        try await source("a", url: a, database: database)
        try FolderScanner.scan(root: a, sourceID: "a", database: database)
        let initial = try await database.files(FileQuery())
        try FileManager.default.moveItem(at: original, to: outside)
        try FolderScanner.scan(root: a, sourceID: "a", database: database)
        let moved = try await database.files(FileQuery())
        XCTAssertEqual(moved.total, 1)
        XCTAssertEqual(moved.files.first?.isAvailable, false)
        try FileManager.default.moveItem(at: outside, to: original)
        try FolderScanner.scan(root: a, sourceID: "a", database: database)
        let restored = try await database.files(FileQuery())
        XCTAssertEqual(restored.files.first?.isAvailable, true)
        XCTAssertEqual(restored.files.first?.id, initial.files.first?.id)
    }

    func testSkipsPackagesAndSymlinksWithoutChangingOriginals() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try folder("A", in: root), outside = try folder("outside", in: root)
        let bytes = Data("unchanged original".utf8)
        let ordinary = a.appendingPathComponent("原件.txt")
        try bytes.write(to: ordinary)
        try bytes.write(to: outside.appendingPathComponent("越界.txt"))
        try FileManager.default.createSymbolicLink(at: a.appendingPathComponent("外部目录"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: a.appendingPathComponent("外部文件.txt"), withDestinationURL: outside.appendingPathComponent("越界.txt"))
        let package = try folder("Example.app", in: a)
        try bytes.write(to: package.appendingPathComponent("内部.txt"))
        let database = try LibraryDatabase(path: ":memory:")
        try await source("a", url: a, database: database)
        try FolderScanner.scan(root: a, sourceID: "a", database: database)
        let result = try await database.files(FileQuery())
        XCTAssertEqual(result.files.map(\.name), ["原件.txt"])
        XCTAssertEqual(try Data(contentsOf: ordinary), bytes)
        try FolderScanner.scan(root: a, sourceID: "a", database: database, preferBulkMetadata: false)
        let fallback = try await database.files(FileQuery(sourceID: "a")).files
        XCTAssertEqual(fallback.map(\.name), ["原件.txt"])
        XCTAssertThrowsError(try FolderAccess.fileURL(relativePath: "外部目录/越界.txt", root: a))
        XCTAssertThrowsError(try FolderAccess.fileURL(relativePath: "../outside/越界.txt", root: a))
    }

    func testFailedScanDoesNotMarkPreviousFilesMissing() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try folder("A", in: root)
        try Data("test".utf8).write(to: a.appendingPathComponent("仍保留.txt"))
        let database = try LibraryDatabase(path: ":memory:")
        try await source("a", url: a, database: database)
        try FolderScanner.scan(root: a, sourceID: "a", database: database)
        try FileManager.default.moveItem(at: a, to: root.appendingPathComponent("renamed"))
        XCTAssertThrowsError(try FolderScanner.scan(root: a, sourceID: "a", database: database))
        let result = try await database.files(FileQuery())
        XCTAssertEqual(result.files.first?.isAvailable, true)
    }

    func testScanningDatabaseParentExcludesOwnSQLiteFilesButKeepsOrdinaryFiles() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = root.appendingPathComponent("发票.txt")
        let similarlyNamed = root.appendingPathComponent("library.sqlite-notes.txt")
        try Data("original receipt".utf8).write(to: receipt)
        try Data("ordinary user document".utf8).write(to: similarlyNamed)
        let database = try LibraryDatabase(path: root.appendingPathComponent("library.sqlite").path)
        try await source("parent", url: root, database: database)

        try FolderScanner.scan(root: root, sourceID: "parent", database: database)

        let files = try await database.files(FileQuery(sourceID: "parent")).files
        XCTAssertEqual(Set(files.map(\.name)), ["发票.txt", "library.sqlite-notes.txt"])
        XCTAssertEqual(try Data(contentsOf: receipt), Data("original receipt".utf8))
    }

    func testUpgradePausesPreviouslyFailedSourcesWithoutLosingObjectLinks() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("legacy.sqlite").path
        let previous = try LibraryDatabase(path: path)
        try await source("failed", url: root.appendingPathComponent("failed"), database: previous)
        try await source("healthy", url: root.appendingPathComponent("healthy"), database: previous)
        try previous.saveBatch([ScannedFile(relativePath: "发票.txt", name: "发票.txt",
            typeIdentifier: "public.plain-text", bytes: 7)], sourceID: "failed", scanID: "previous")
        let rows = try await previous.files(FileQuery(sourceID: "failed")).files
        let receiptID = try XCTUnwrap(rows.first?.id)
        try await previous.saveObject(id: "computer", name: "我的电脑", kind: "device", notes: "保留的整理")
        try await previous.linkItems([receiptID], to: "computer")
        try await previous.setSourceError("failed", message: "未能完整读取文件夹")
        // Reproduce the last released schema, including its persisted failure.
        try await previous.queue.write { db in
            try db.execute(sql: "ALTER TABLE source DROP COLUMN autoUpdatePaused")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='source-auto-update-pause'")
        }
        try previous.queue.close()

        let upgraded = try LibraryDatabase(path: path)
        let upgradedSources = try await upgraded.sources()
        XCTAssertEqual(upgradedSources.first { $0.id == "failed" }?.autoUpdatePaused, true)
        XCTAssertEqual(upgradedSources.first { $0.id == "healthy" }?.autoUpdatePaused, false)
        let linked = try await upgraded.files(FileQuery(objectID: "computer")).files
        XCTAssertEqual(linked.map(\.id), [receiptID])
        XCTAssertEqual(linked.first?.isAvailable, true)
        // Bookmark renewal must preserve a manual pause.
        try await upgraded.saveSource(id: "failed", name: "failed", path: root.appendingPathComponent("failed").path,
            bookmark: Data([2]))
        let renewed = try await upgraded.sources()
        XCTAssertEqual(renewed.first { $0.id == "failed" }?.autoUpdatePaused, true)
        try upgraded.queue.close()
    }

    func testLiteralSearchPathSearchSortingAndPagination() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try folder("A", in: root)
        let nested = try folder("发票", in: a)
        try Data([1]).write(to: nested.appendingPathComponent("100%_折扣.txt"))
        try Data([1, 2, 3]).write(to: a.appendingPathComponent("其它.txt"))
        let database = try LibraryDatabase(path: ":memory:")
        try await source("a", url: a, database: database)
        try FolderScanner.scan(root: a, sourceID: "a", database: database)
        let literal = try await database.files(FileQuery(search: "%_"))
        let nestedResult = try await database.files(FileQuery(search: "发票 折扣"))
        let page = try await database.files(FileQuery(sort: .size, ascending: false, limit: 1))
        XCTAssertEqual(literal.total, 1)
        XCTAssertEqual(nestedResult.total, 1)
        XCTAssertEqual(page.total, 2)
        XCTAssertEqual(page.files.count, 1)
        XCTAssertEqual(page.files.first?.bytes, 3)
    }

    func testSparseGlobalSearchKeepsSortingOffsetAndCountOnlySemantics() async throws {
        let database = try LibraryDatabase(path: ":memory:")
        try await source("a", url: URL(fileURLWithPath: "/synthetic"), database: database)
        try database.saveBatch(["B-match.txt", "a-match.txt", "unrelated.txt"].map {
            ScannedFile(relativePath: $0, name: $0, typeIdentifier: "public.plain-text", bytes: 1)
        }, sourceID: "a", scanID: "synthetic")

        let all = try await database.files(FileQuery(search: "match", limit: 10))
        let offset = try await database.files(FileQuery(search: "match", ascending: false, limit: 10, offset: 1))
        let paginated = try await database.files(FileQuery(search: "match", limit: 1))
        let countOnly = try await database.files(FileQuery(search: "match", limit: 0))
        let missing = try await database.files(FileQuery(search: "no-result"))
        XCTAssertEqual(all.files.map(\.name), ["a-match.txt", "B-match.txt"])
        XCTAssertEqual(offset.files.map(\.name), ["a-match.txt"])
        XCTAssertEqual(paginated.files.map(\.id), [all.files[0].id])
        XCTAssertEqual(countOnly.total, 2)
        XCTAssertTrue(countOnly.files.isEmpty)
        XCTAssertEqual(missing.total, 0)
        XCTAssertTrue(missing.files.isEmpty)
    }

    func testUnreadableChildEndsScanWithSpecificWarningAndKeepsOtherFilesSearchable() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try folder("A", in: root)
        let restricted = try folder("Restricted", in: a)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path) }
        try Data("readable".utf8).write(to: a.appendingPathComponent("正常资料.txt"))
        try Data("restricted".utf8).write(to: restricted.appendingPathComponent("历史凭证.txt"))
        let removed = a.appendingPathComponent("已移走.txt")
        try Data("removed".utf8).write(to: removed)
        let database = try LibraryDatabase(path: ":memory:")
        try await source("a", url: a, database: database)
        try FolderScanner.scan(root: a, sourceID: "a", database: database)
        let initial = try await database.files(FileQuery(sourceID: "a")).files
        let ordinary = try XCTUnwrap(initial.first { $0.name == "正常资料.txt" })
        let historical = try XCTUnwrap(initial.first { $0.name == "历史凭证.txt" })
        try await database.saveDocumentText(itemID: ordinary.id, text: "ordinary-nebula")
        try await database.saveDocumentText(itemID: historical.id, text: "restricted-nebula")
        try await database.saveObject(id: "object", name: "保留的对象", kind: "other", notes: "")
        try await database.linkItems([historical.id], to: "object")
        try FileManager.default.removeItem(at: removed)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: restricted.path)

        let report = try FolderScanner.scan(root: a, sourceID: "a", database: database)

        XCTAssertEqual(report.fileCount, 1)
        XCTAssertEqual(report.unreadable.map(\.path), ["Restricted"])
        let stored = try await database.sources().first
        XCTAssertNil(stored?.lastError)
        XCTAssertNotNil(stored?.lastScannedAt)
        XCTAssertEqual(stored?.scanReport?.unreadable.map(\.path), ["Restricted"])
        let protectedFile = try await database.file(id: historical.id)
        XCTAssertEqual(protectedFile?.isAvailable, true)
        XCTAssertNotNil(protectedFile?.sourceError)
        let gone = try await database.files(FileQuery(search: "已移走", sourceID: "a")).files
        XCTAssertEqual(gone.first?.isAvailable, false)
        let ordinaryText = try await database.files(FileQuery(search: "ordinary-nebula", searchBody: true))
        XCTAssertEqual(ordinaryText.files.map(\.id), [ordinary.id])
        let protectedText = try await database.files(FileQuery(search: "restricted-nebula", searchBody: true))
        XCTAssertEqual(protectedText.total, 0)
        let links = try await database.files(FileQuery(objectID: "object")).files
        XCTAssertEqual(links.map(\.id), [historical.id])

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path)
        let recovered = try FolderScanner.scan(root: a, sourceID: "a", database: database, scope: "Restricted")
        XCTAssertTrue(recovered.unreadable.isEmpty)
        let refreshed = try await database.file(id: historical.id)
        XCTAssertNil(refreshed?.sourceError)
        let recoveredSources = try await database.sources()
        XCTAssertTrue(recoveredSources.first?.scanReport?.unreadable.isEmpty == true)
    }

    func testScopedRefreshDoesNotInvalidateUnrelatedDocumentsAndHandlesDirectoryRemoval() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try folder("A", in: root)
        let nested = try folder("Nested", in: a)
        try Data("unrelated".utf8).write(to: a.appendingPathComponent("保留.txt"))
        try Data("old".utf8).write(to: nested.appendingPathComponent("变化.txt"))
        let database = try LibraryDatabase(path: ":memory:")
        try await source("a", url: a, database: database)
        let full = try FolderScanner.scan(root: a, sourceID: "a", database: database)
        try Data("updated content".utf8).write(to: nested.appendingPathComponent("变化.txt"))
        let changed = try FolderScanner.scan(root: a, sourceID: "a", database: database, scope: "Nested/变化.txt")
        XCTAssertEqual(changed.fileCount, 1)
        let rows = try await database.files(FileQuery(sourceID: "a")).files
        XCTAssertEqual(rows.filter(\.isAvailable).count, 2)
        XCTAssertEqual(rows.first { $0.name == "变化.txt" }?.bytes, 15)
        let stored = try await database.sources()
        XCTAssertEqual(stored.first?.scanReport?.completedAt.timeIntervalSince1970 ?? 0,
                       full.completedAt.timeIntervalSince1970, accuracy: 0.001)
        try FileManager.default.removeItem(at: nested)
        try FolderScanner.scan(root: a, sourceID: "a", database: database, scope: "Nested")
        let after = try await database.files(FileQuery(sourceID: "a")).files
        XCTAssertEqual(after.first { $0.name == "变化.txt" }?.isAvailable, false)
        XCTAssertEqual(after.first { $0.name == "保留.txt" }?.isAvailable, true)
    }

    func testScopedRefreshRetiresOldPathsBehindSkippedOrReplacedAncestors() async throws {
        for mode in ["hidden", "package", "symlink", "file", "missing"] {
            let root = try workspace()
            defer { try? FileManager.default.removeItem(at: root) }
            let a = try folder("A", in: root)
            let parentName = mode == "package" ? "Parent.app" : "Parent"
            let parent = try folder(parentName, in: a)
            try Data("original".utf8).write(to: parent.appendingPathComponent("child.txt"))
            try Data("unrelated".utf8).write(to: a.appendingPathComponent("keep.txt"))
            let path = parentName + "/child.txt"
            let database = try LibraryDatabase(path: ":memory:")
            try await source("a", url: a, database: database)
            // Represent records retained from when this was an ordinary directory.
            try database.saveBatch([path, "keep.txt"].map {
                ScannedFile(relativePath: $0, name: ($0 as NSString).lastPathComponent,
                    typeIdentifier: "public.plain-text", bytes: 8)
            }, sourceID: "a", scanID: "before")
            let initial = try await database.files(FileQuery(sourceID: "a")).files
            let child = try XCTUnwrap(initial.first { $0.relativePath == path })
            try await database.saveDocumentText(itemID: child.id, text: "ancestor-quartz")
            switch mode {
            case "hidden": XCTAssertEqual(chflags(parent.path, UInt32(UF_HIDDEN)), 0)
            case "symlink":
                let outside = root.appendingPathComponent("outside")
                try FileManager.default.moveItem(at: parent, to: outside)
                try Data("never indexed".utf8).write(to: outside.appendingPathComponent("outside-only.txt"))
                try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
            case "file":
                try FileManager.default.removeItem(at: parent)
                try Data("replaced directory".utf8).write(to: parent)
            case "missing": try FileManager.default.removeItem(at: parent)
            default: break
            }
            let report = try FolderScanner.scan(root: a, sourceID: "a", database: database, scope: path)
            XCTAssertEqual(report.fileCount, 0, mode)
            XCTAssertTrue(report.unreadable.isEmpty, mode)
            let after = try await database.files(FileQuery(sourceID: "a")).files
            XCTAssertEqual(after.count, 2, mode)
            XCTAssertEqual(after.first { $0.id == child.id }?.isAvailable, false, mode)
            XCTAssertEqual(after.first { $0.name == "keep.txt" }?.isAvailable, true, mode)
            let staleBody = try await database.files(FileQuery(search: "ancestor-quartz", searchBody: true))
            XCTAssertEqual(staleBody.total, 0, mode)
        }
    }

    func testRemovingSourceOnlyRemovesIndex() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try folder("A", in: root)
        let original = a.appendingPathComponent("原件.txt")
        try Data("keep".utf8).write(to: original)
        let database = try LibraryDatabase(path: ":memory:")
        try await source("a", url: a, database: database)
        try FolderScanner.scan(root: a, sourceID: "a", database: database)
        try await database.removeSource("a")
        let result = try await database.files(FileQuery())
        XCTAssertEqual(result.total, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }
}
