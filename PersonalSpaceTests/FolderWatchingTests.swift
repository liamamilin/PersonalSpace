import XCTest
@testable import PersonalSpace

@MainActor
final class FolderWatchingTests: XCTestCase {
    private func workspace() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let root = support.appendingPathComponent("M9Tests").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func source(_ name: String, root: URL, database: LibraryDatabase) async throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await database.saveSource(id: name, name: name, path: folder.path,
            bookmark: FolderAccess.bookmark(for: folder))
        return folder
    }

    private func waitForFiles(_ count: Int, sourceID: String, database: LibraryDatabase,
                              model: LibraryModel) async throws {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            let files = try await database.files(FileQuery(sourceID: sourceID)).files
            if files.filter(\.isAvailable).count == count, model.scanning[sourceID] == nil { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        let actual = try await database.files(FileQuery(sourceID: sourceID)).files.filter(\.isAvailable).count
        XCTFail("Real FSEvents timed out after 12s for source \(sourceID): expected \(count) available files, found \(actual); watching=\(model.monitoredSourceIDs), loaded=\(model.sources.map(\.id)), scanning=\(model.scanning), errors=\(model.monitoringErrors)")
    }

    func testRealEventsRefreshMetadataAndPreserveUnavailableEvidenceAndManagedCopy() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try LibraryDatabase(path: root.appendingPathComponent("library.sqlite").path)
        let a = try await source("A", root: root, database: database)
        let file = a.appendingPathComponent("凭证.txt")
        try Data("original".utf8).write(to: file)
        let model = LibraryModel(database: database)
        await model.start()
        XCTAssertEqual(model.monitoredSourceIDs, ["A"])
        try await waitForFiles(1, sourceID: "A", database: database, model: model)
        let indexed = try await database.files(FileQuery(sourceID: "A")).files
        let item = try XCTUnwrap(indexed.first)
        try await database.saveObject(id: "object", name: "合成设备", kind: "device", notes: "")
        try await database.linkItems([item.id], to: "object")
        try await database.saveMatter(MatterDraft(id: "matter", title: "合成事务", itemIDs: [item.id],
            facts: [FactDraft(key: "product", valueText: "合成设备", sourceItemID: item.id)]))
        let store = ManagedFileStore(root: root.appendingPathComponent("Vault"))
        let copy = try store.copy(sourceURL: file)
        try await database.saveManagedCopy(itemID: item.id, relativePath: copy.relativePath, sha256: copy.sha256)

        try Data("updated metadata with different size".utf8).write(to: file)
        let deadline = Date().addingTimeInterval(12)
        var updated: LibraryFile?
        while Date() < deadline {
            updated = try await database.file(id: item.id)
            if updated?.bytes == 36, model.scanning["A"] == nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(updated?.bytes, 36)
        let outside = root.appendingPathComponent("moved.txt")
        try FileManager.default.moveItem(at: file, to: outside)
        try await waitForFiles(0, sourceID: "A", database: database, model: model)
        let missing = try await database.file(id: item.id)
        XCTAssertEqual(missing?.isAvailable, false)
        XCTAssertEqual(missing?.managedCopyPath, copy.relativePath)
        let facts = try await database.facts(matterID: "matter")
        XCTAssertEqual(facts.first?.sourceItemID, item.id)
        let links = try await database.files(FileQuery(objectID: "object"))
        XCTAssertEqual(links.files.first?.id, item.id)
        XCTAssertEqual(try Data(contentsOf: store.url(for: copy.relativePath)), Data("original".utf8))
        try FileManager.default.moveItem(at: outside, to: file)
        try await waitForFiles(1, sourceID: "A", database: database, model: model)
        let restored = try await database.file(id: item.id)
        XCTAssertEqual(restored?.id, item.id)
        XCTAssertEqual(restored?.isAvailable, true)
    }

    func testBurstAndTwoSourcesSettleAndRemovalStopsOnlyThatSource() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try LibraryDatabase(path: root.appendingPathComponent("library.sqlite").path)
        let a = try await source("A", root: root, database: database)
        let b = try await source("B", root: root, database: database)
        let model = LibraryModel(database: database)
        await model.start()
        XCTAssertEqual(model.monitoredSourceIDs, ["A", "B"])
        try await waitForFiles(0, sourceID: "A", database: database, model: model)
        try await waitForFiles(0, sourceID: "B", database: database, model: model)
        for index in 0..<20 {
            try Data("synthetic \(index)".utf8).write(to: a.appendingPathComponent("a\(index).txt"))
            try Data("synthetic \(index)".utf8).write(to: b.appendingPathComponent("b\(index).txt"))
        }
        try await waitForFiles(20, sourceID: "A", database: database, model: model)
        try await waitForFiles(20, sourceID: "B", database: database, model: model)
        // Native events can arrive in more than one batch. Allow the expected
        // follow-up scan, then require a quiet tail rather than exactly one scan.
        var last = try await database.sources().map(\.lastScannedAt)
        var lastChange = Date()
        let observationEnd = Date().addingTimeInterval(10)
        while Date() < observationEnd {
            try await Task.sleep(for: .milliseconds(200))
            let current = try await database.sources().map(\.lastScannedAt)
            if current != last { last = current; lastChange = Date() }
        }
        XCTAssertGreaterThan(Date().timeIntervalSince(lastChange), 3, "No continuing self-induced scan storm")
        XCTAssertTrue(model.scanning.isEmpty)
        let sources = try await database.sources()
        try await model.remove(XCTUnwrap(sources.first { $0.id == "A" }))
        XCTAssertEqual(model.monitoredSourceIDs, ["B"])
        try Data("ignored".utf8).write(to: a.appendingPathComponent("after-removal.txt"))
        try Data("still watched".utf8).write(to: b.appendingPathComponent("still-watched.txt"))
        try await waitForFiles(21, sourceID: "B", database: database, model: model)
        let removed = try await database.files(FileQuery(sourceID: "A"))
        XCTAssertFalse(removed.files.contains { $0.name == "after-removal.txt" })
    }

    func testInvalidAuthorizationDoesNotBlockOtherSource() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try LibraryDatabase(path: ":memory:")
        try await database.saveSource(id: "bad", name: "bad", path: root.appendingPathComponent("missing").path, bookmark: Data([1]))
        try database.saveBatch([ScannedFile(relativePath: "history.txt", name: "history.txt", typeIdentifier: "public.text", bytes: 4)], sourceID: "bad", scanID: "old")
        let good = try await source("good", root: root, database: database)
        let model = LibraryModel(database: database)
        await model.start()
        XCTAssertNotNil(model.monitoringErrors["bad"])
        XCTAssertEqual(model.monitoredSourceIDs, ["good"])
        // Wait for the startup scan to finish so only a real event can find new.txt.
        try await waitForFiles(0, sourceID: "good", database: database, model: model)
        try Data("real event".utf8).write(to: good.appendingPathComponent("new.txt"))
        try await waitForFiles(1, sourceID: "good", database: database, model: model)
        let history = try await database.files(FileQuery(sourceID: "bad"))
        XCTAssertEqual(history.files.first?.name, "history.txt")
        XCTAssertEqual(history.files.first?.isAvailable, true)
    }

    func testStartupRestoresMonitoringDuringConcurrentViewReloads() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try LibraryDatabase(path: root.appendingPathComponent("library.sqlite").path)
        let folder = try await source("persisted", root: root, database: database)
        try Data("startup file".utf8).write(to: folder.appendingPathComponent("existing.txt"))
        let model = LibraryModel(database: database)
        async let startup: Void = model.start()
        for _ in 0..<30 { await model.reload() }
        await startup
        XCTAssertEqual(model.monitoredSourceIDs, ["persisted"])
        try await waitForFiles(1, sourceID: "persisted", database: database, model: model)
        try Data("after startup".utf8).write(to: folder.appendingPathComponent("new.txt"))
        try await waitForFiles(2, sourceID: "persisted", database: database, model: model)
    }

    func testContinuousChangesRefreshBeforeQuietWithoutBlockingOtherSource() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try LibraryDatabase(path: root.appendingPathComponent("library.sqlite").path)
        let a = try await source("A", root: root, database: database)
        let b = try await source("B", root: root, database: database)
        let activity = a.appendingPathComponent("activity.log")
        try Data("initial".utf8).write(to: activity)
        let model = LibraryModel(database: database)
        await model.start()
        try await waitForFiles(1, sourceID: "A", database: database, model: model)
        try await waitForFiles(0, sourceID: "B", database: database, model: model)

        // Keep real FSEvents arriving beyond the assertion deadline. A trailing
        // debounce alone cannot discover new.txt until this writer becomes quiet.
        let writer = Task.detached {
            let end = ContinuousClock.now.advanced(by: .seconds(12))
            var sequence = 0
            while ContinuousClock.now < end {
                try Task.checkCancellation()
                try Data("synthetic update \(sequence)".utf8).write(to: activity)
                sequence += 1
                try await Task.sleep(for: .milliseconds(150))
            }
        }
        defer { writer.cancel() }
        try Data("active source".utf8).write(to: a.appendingPathComponent("new.txt"))
        try Data("independent source".utf8).write(to: b.appendingPathComponent("new.txt"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        var aUpdated = false, bUpdated = false
        while ContinuousClock.now < deadline {
            aUpdated = try await database.files(FileQuery(sourceID: "A")).files.filter(\.isAvailable).count == 2 && model.scanning["A"] == nil
            bUpdated = try await database.files(FileQuery(sourceID: "B")).files.filter(\.isAvailable).count == 1 && model.scanning["B"] == nil
            if aUpdated && bUpdated { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(aUpdated, "Continuous events must not postpone refresh until the source becomes quiet")
        XCTAssertTrue(bUpdated, "Changes in A must not block source B")
        writer.cancel()
        _ = try? await writer.value
    }

    func testHiddenLogChangesDoNotRescanButVisibleChangesStillRefresh() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try LibraryDatabase(path: root.appendingPathComponent("library.sqlite").path)
        let folder = try await source("A", root: root, database: database)
        try Data("visible".utf8).write(to: folder.appendingPathComponent("visible.txt"))
        let hidden = folder.appendingPathComponent(".activity.log")
        try Data("hidden".utf8).write(to: hidden)
        let model = LibraryModel(database: database)
        await model.start()
        try await waitForFiles(1, sourceID: "A", database: database, model: model)
        // Settle the initial directory events before measuring hidden-only writes.
        try await Task.sleep(for: .seconds(2))
        let initial = try await database.sources().first?.lastScannedAt
        XCTAssertNotNil(initial)
        for sequence in 0..<36 {
            try Data("hidden update \(sequence)".utf8).write(to: hidden)
            try await Task.sleep(for: .milliseconds(150))
        }
        try await Task.sleep(for: .seconds(2))
        let afterHidden = try await database.sources().first?.lastScannedAt
        XCTAssertEqual(afterHidden, initial, "Excluded hidden content must not trigger a full rescan")
        try Data("new visible content".utf8).write(to: folder.appendingPathComponent("new.txt"))
        try await waitForFiles(2, sourceID: "A", database: database, model: model)
    }

    func testAuthorizedHiddenRootRefreshesVisibleFilesAndTheirRemoval() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try LibraryDatabase(path: root.appendingPathComponent("library.sqlite").path)
        let folder = try await source(".chosen", root: root, database: database)
        let model = LibraryModel(database: database)
        await model.start()
        try await waitForFiles(0, sourceID: ".chosen", database: database, model: model)
        let visible = folder.appendingPathComponent("visible.txt")
        try Data("visible".utf8).write(to: visible)
        try await waitForFiles(1, sourceID: ".chosen", database: database, model: model)
        let files = try await database.files(FileQuery(sourceID: ".chosen")).files
        let id = try XCTUnwrap(files.first?.id)
        try FileManager.default.moveItem(at: visible, to: folder.appendingPathComponent(".hidden.txt"))
        try await waitForFiles(0, sourceID: ".chosen", database: database, model: model)
        let missing = try await database.file(id: id)
        XCTAssertNotNil(missing)
        XCTAssertEqual(missing?.isAvailable, false)
    }

    func testHiddenHardLinkChangesStillRefreshVisibleFileMetadata() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try LibraryDatabase(path: root.appendingPathComponent("library.sqlite").path)
        let folder = try await source("A", root: root, database: database)
        let visible = folder.appendingPathComponent("receipt.txt")
        try Data("original".utf8).write(to: visible)
        let hidden = folder.appendingPathComponent(".linked.txt")
        try FileManager.default.linkItem(at: visible, to: hidden)
        let model = LibraryModel(database: database)
        await model.start()
        try await waitForFiles(1, sourceID: "A", database: database, model: model)
        let payload = Data("updated through a hidden hard link".utf8)
        let handle = try FileHandle(forWritingTo: hidden)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: payload)
        try handle.close()
        XCTAssertEqual(try Data(contentsOf: visible), payload)
        let deadline = Date().addingTimeInterval(12)
        var bytes: Int64?
        while Date() < deadline {
            let files = try await database.files(FileQuery(sourceID: "A")).files
            bytes = files.first?.bytes
            if bytes == Int64(payload.count), model.scanning["A"] == nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(bytes, Int64(payload.count))
    }

}
