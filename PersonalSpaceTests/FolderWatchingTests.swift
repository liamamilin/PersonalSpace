import XCTest
import CoreServices
@testable import PersonalSpace

@MainActor
final class FolderWatchingTests: XCTestCase {
    func testDirectoryNoiseDoesNotExpandFileEventsIntoSubtreeScans() {
        let events: [(path: String, flags: FSEventStreamEventFlags)] = [
            ("/synthetic/Library", UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemModified)),
            ("/synthetic/Library", UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemXattrMod)),
            ("/synthetic/Library/.cache/log", UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified)),
            ("/synthetic/Documents/receipt.txt", UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified))
        ]
        XCTAssertEqual(FolderWatcher.pathsToScan(rootPrefixes: ["/synthetic/"],
            exclusions: FolderScanExclusions(), events: events), ["Documents/receipt.txt"])
    }

    func testCoalescedSubtreeEventDoesNotRestartWholeSourceButDropsDo() {
        let subdir = (path: "/synthetic/Library", flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs))
        XCTAssertEqual(FolderWatcher.pathsToScan(rootPrefixes: ["/synthetic/"],
            exclusions: FolderScanExclusions(), events: [subdir]), ["Library"])
        let dropped = (path: subdir.path, flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagKernelDropped))
        XCTAssertNil(FolderWatcher.pathsToScan(rootPrefixes: ["/synthetic/"],
            exclusions: FolderScanExclusions(), events: [dropped]))
        let root = (path: "/synthetic", flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs))
        XCTAssertNil(FolderWatcher.pathsToScan(rootPrefixes: ["/synthetic/"],
            exclusions: FolderScanExclusions(), events: [root]))
    }

    func testDirectoryPermissionVisibilityAndRenameEventsStillReconcile() {
        for flag in [kFSEventStreamEventFlagItemCreated, kFSEventStreamEventFlagItemRemoved,
                     kFSEventStreamEventFlagItemRenamed, kFSEventStreamEventFlagItemInodeMetaMod,
                     kFSEventStreamEventFlagItemChangeOwner, kFSEventStreamEventFlagItemFinderInfoMod] {
            XCTAssertEqual(FolderWatcher.pathsToScan(rootPrefixes: ["/synthetic/"],
                exclusions: FolderScanExclusions(), events: [("/synthetic/Documents", UInt32(flag | kFSEventStreamEventFlagItemIsDir))]), ["Documents"])
        }
    }

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
        let database = try LibraryDatabase(path: root.appendingPathComponent("library.sqlite").path)
        let folder = try await source("persisted", root: root, database: database)
        try Data("startup file".utf8).write(to: folder.appendingPathComponent("existing.txt"))
        let model = LibraryModel(database: database)
        // A scan can have finished enumeration while its final UI read is still
        // running. Stop and drain it before unlinking this disposable SQLite file.
        addTeardownBlock {
            for source in try await database.sources() { await model.remove(source) }
            try database.queue.close()
            try FileManager.default.removeItem(at: root)
        }
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

    func testDatabaseInsideWatchedSourceSettlesAndStillFindsNewDocuments() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try LibraryDatabase(path: root.appendingPathComponent("library.sqlite").path)
        try await database.saveSource(id: "parent", name: "合成父目录", path: root.path,
            bookmark: FolderAccess.bookmark(for: root))
        try Data("receipt".utf8).write(to: root.appendingPathComponent("发票.txt"))
        let model = LibraryModel(database: database)
        await model.start()
        try await waitForFiles(1, sourceID: "parent", database: database, model: model)
        try await Task.sleep(for: .seconds(2))
        let initial = try await database.sources().first?.lastScannedAt

        // Writes to the real SQLite database must not trigger scans of its parent.
        for sequence in 0..<20 {
            try await database.saveObject(id: "computer", name: "合成设备", kind: "device", notes: "update \(sequence)")
            try await Task.sleep(for: .milliseconds(150))
        }
        try await Task.sleep(for: .seconds(2))
        let afterWrites = try await database.sources().first?.lastScannedAt
        XCTAssertEqual(afterWrites, initial, "The app's own database must not keep restarting its scanner")
        XCTAssertTrue(model.scanning.isEmpty)
        XCTAssertEqual(model.monitoredSourceIDs, ["parent"])

        try Data("warranty".utf8).write(to: root.appendingPathComponent("保修单.txt"))
        try await waitForFiles(2, sourceID: "parent", database: database, model: model)
        let files = try await database.files(FileQuery(sourceID: "parent")).files
        XCTAssertEqual(Set(files.map(\.name)), ["发票.txt", "保修单.txt"])
    }

    func testStopPersistsAcrossRestartAndManualRefreshDoesNotResumeWatching() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try LibraryDatabase(path: root.appendingPathComponent("library.sqlite").path)
        let a = try await source("A", root: root, database: database)
        let b = try await source("B", root: root, database: database)
        let model = LibraryModel(database: database)
        await model.start()
        try await waitForFiles(0, sourceID: "A", database: database, model: model)
        try await waitForFiles(0, sourceID: "B", database: database, model: model)
        let storedSources = try await database.sources()
        let stopped = try XCTUnwrap(storedSources.first { $0.id == "A" })
        model.cancelScan(stopped)
        XCTAssertEqual(model.monitoredSourceIDs, ["B"])
        try Data("paused".utf8).write(to: a.appendingPathComponent("new.txt"))
        try Data("still active".utf8).write(to: b.appendingPathComponent("new.txt"))
        try await waitForFiles(1, sourceID: "B", database: database, model: model)

        let restarted = LibraryModel(database: database)
        await restarted.start()
        XCTAssertFalse(restarted.monitoredSourceIDs.contains("A"))
        XCTAssertNil(restarted.scanning["A"])
        let pausedSources = try await database.sources()
        let paused = try XCTUnwrap(pausedSources.first { $0.id == "A" })
        XCTAssertTrue(paused.autoUpdatePaused)
        let beforeRefresh = try await database.files(FileQuery(sourceID: "A"))
        XCTAssertEqual(beforeRefresh.total, 0)

        restarted.refresh(paused)
        try await waitForFiles(1, sourceID: "A", database: database, model: restarted)
        XCTAssertFalse(restarted.monitoredSourceIDs.contains("A"), "A one-off refresh must leave automatic updates paused")
        await restarted.resumeAutomaticUpdates(paused)
        try await waitForFiles(1, sourceID: "A", database: database, model: restarted)
        XCTAssertTrue(restarted.monitoredSourceIDs.contains("A"))
        let resumedSources = try await database.sources()
        XCTAssertEqual(resumedSources.first { $0.id == "A" }?.autoUpdatePaused, false)
        try Data("after resume".utf8).write(to: a.appendingPathComponent("resumed.txt"))
        try await waitForFiles(2, sourceID: "A", database: database, model: restarted)
    }

    func testAppStorageSubtreeIsExcludedFromScanningAndNativeEvents() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let appStorage = root.appendingPathComponent("AppStorage")
        let ordinary = root.appendingPathComponent("AppStorage-documents")
        try FileManager.default.createDirectory(at: appStorage, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: ordinary, withIntermediateDirectories: false)
        let database = try LibraryDatabase(path: appStorage.appendingPathComponent("library.sqlite").path)
        try await database.saveSource(id: "parent", name: "合成父目录", path: root.path, bookmark: Data())
        try Data("ordinary receipt".utf8).write(to: ordinary.appendingPathComponent("发票.txt"))
        let exclusions = FolderScanExclusions(databasePath: database.queue.path, directories: [appStorage])
        try FolderScanner.scan(root: root, sourceID: "parent", database: database, exclusions: exclusions)
        let scanned = try await database.files(FileQuery(sourceID: "parent")).files
        XCTAssertEqual(scanned.map(\.relativePath), ["AppStorage-documents/发票.txt"])

        var events = 0
        let watcher = try FolderWatcher(root: root, exclusions: exclusions) { _ in events += 1 }
        defer { watcher.stop() }
        try await Task.sleep(for: .seconds(2))
        let initial = events
        for index in 0..<10 {
            try Data("internal state \(index)".utf8).write(to: appStorage.appendingPathComponent("state.json"), options: .atomic)
            try await Task.sleep(for: .milliseconds(150))
        }
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(events, initial, "Changes anywhere in app storage must not trigger a source refresh")
        try Data("visible change".utf8).write(to: ordinary.appendingPathComponent("new.txt"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while events == initial, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertGreaterThan(events, initial, "A similarly named user folder must still be watched")
    }

    func testUnreadableSubfolderDoesNotStopWatchingAndFileEventsDoNotRestartFullScan() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try LibraryDatabase(path: root.appendingPathComponent("library.sqlite").path)
        let a = try await source("A", root: root, database: database)
        let restricted = a.appendingPathComponent("Restricted")
        try FileManager.default.createDirectory(at: restricted, withIntermediateDirectories: false)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path) }
        let ordinary = a.appendingPathComponent("ordinary.txt")
        try Data("ordinary".utf8).write(to: ordinary)
        try Data("historical".utf8).write(to: restricted.appendingPathComponent("receipt.txt"))
        let model = LibraryModel(database: database)
        await model.start()
        try await waitForFiles(2, sourceID: "A", database: database, model: model)
        let initialSources = try await database.sources()
        let completed = try XCTUnwrap(initialSources.first?.scanReport?.completedAt)

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: restricted.path)
        var deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while ContinuousClock.now < deadline {
            let sources = try await database.sources()
            if sources.first?.scanReport?.unreadable.map(\.path) == ["Restricted"], model.scanning["A"] == nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        var stored = try await database.sources()
        XCTAssertEqual(stored.first?.scanReport?.unreadable.map(\.path), ["Restricted"])
        XCTAssertEqual(model.monitoredSourceIDs, ["A"])
        XCTAssertEqual(stored.first?.autoUpdatePaused, false)
        XCTAssertNil(stored.first?.lastError)

        let payload = Data("updated ordinary content".utf8)
        try payload.write(to: ordinary)
        deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while ContinuousClock.now < deadline {
            let files = try await database.files(FileQuery(sourceID: "A")).files
            if files.first(where: { $0.name == "ordinary.txt" })?.bytes == Int64(payload.count), model.scanning["A"] == nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        stored = try await database.sources()
        XCTAssertEqual(stored.first?.scanReport?.completedAt.timeIntervalSince1970 ?? 0, completed.timeIntervalSince1970, accuracy: 0.001)
        let updated = try await database.files(FileQuery(sourceID: "A")).files
        XCTAssertEqual(updated.first { $0.name == "ordinary.txt" }?.bytes, Int64(payload.count))
        XCTAssertNil(updated.first { $0.name == "ordinary.txt" }?.sourceError)
        XCTAssertNotNil(updated.first { $0.name == "receipt.txt" }?.sourceError)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path)
        deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while ContinuousClock.now < deadline {
            let sources = try await database.sources()
            if sources.first?.scanReport?.unreadable.isEmpty == true, model.scanning["A"] == nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        stored = try await database.sources()
        XCTAssertTrue(stored.first?.scanReport?.unreadable.isEmpty == true)
        XCTAssertEqual(stored.first?.scanReport?.completedAt.timeIntervalSince1970 ?? 0, completed.timeIntervalSince1970, accuracy: 0.001)
    }

    func testStoppingQueuedScanDropsFollowUpAndPreservesHistoricalAvailability() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try LibraryDatabase(path: root.appendingPathComponent("library.sqlite").path)
        let folder = try await source("A", root: root, database: database)
        let receipt = folder.appendingPathComponent("发票.txt")
        try Data("original receipt".utf8).write(to: receipt)
        let model = LibraryModel(database: database)
        await model.start()
        try await waitForFiles(1, sourceID: "A", database: database, model: model)
        let before = try await database.files(FileQuery(sourceID: "A")).files
        let storedSources = try await database.sources()
        let source = try XCTUnwrap(storedSources.first)
        try FileManager.default.moveItem(at: receipt, to: root.appendingPathComponent("outside.txt"))
        // Neither queued task can run until this main-actor turn yields.
        model.refresh(source)
        model.refresh(source)
        model.cancelScan(source)
        await model.waitForScans([source.id])

        XCTAssertNil(model.scanning[source.id])
        XCTAssertFalse(model.monitoredSourceIDs.contains(source.id))
        let after = try await database.file(id: XCTUnwrap(before.first?.id))
        XCTAssertEqual(after?.isAvailable, true, "An interrupted scan must not turn historical evidence into missing files")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("outside.txt")), Data("original receipt".utf8))
        let persisted = try await database.sources()
        XCTAssertEqual(persisted.first?.autoUpdatePaused, true)
        XCTAssertNil(persisted.first?.lastError)
    }

    func testFailedScanPausesAutomaticRetriesAndPreservesExistingRecords() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try LibraryDatabase(path: root.appendingPathComponent("library.sqlite").path)
        let folder = try await source("A", root: root, database: database)
        try Data("receipt".utf8).write(to: folder.appendingPathComponent("发票.txt"))
        let model = LibraryModel(database: database)
        await model.start()
        try await waitForFiles(1, sourceID: "A", database: database, model: model)
        let storedSources = try await database.sources()
        let source = try XCTUnwrap(storedSources.first)
        model.cancelScan(source)
        try FileManager.default.removeItem(at: folder)
        try Data("now a regular file".utf8).write(to: folder)
        model.refresh(source)
        await model.waitForScans([source.id])

        let failed = try await database.sources()
        XCTAssertNotNil(failed.first?.lastError)
        XCTAssertEqual(failed.first?.autoUpdatePaused, true)
        XCTAssertTrue(model.monitoredSourceIDs.isEmpty)
        let files = try await database.files(FileQuery(sourceID: "A")).files
        XCTAssertEqual(files.first?.isAvailable, true)
        let restarted = LibraryModel(database: database)
        await restarted.start()
        XCTAssertTrue(restarted.scanning.isEmpty)
        XCTAssertTrue(restarted.monitoredSourceIDs.isEmpty)
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
