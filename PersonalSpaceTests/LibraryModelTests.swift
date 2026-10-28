import GRDB
import XCTest
@testable import PersonalSpace

@MainActor
final class LibraryModelTests: XCTestCase {
    func testStaleOrdinaryFileCannotReadOrFeedModelAfterSensitiveClassification() async throws {
        let database = try LibraryDatabase(path: ":memory:")
        try await database.saveSource(id: "sensitive-source", name: "合成来源", path: "/synthetic/sensitive", bookmark: Data([1]))
        try database.saveBatch([ScannedFile(relativePath: "普通凭证.txt", name: "普通凭证.txt",
            typeIdentifier: "public.plain-text", bytes: 10)], sourceID: "sensitive-source", scanID: "seed")
        let rows = try await database.files(FileQuery()).files
        let stale = try XCTUnwrap(rows.first)
        XCTAssertEqual(stale.sensitivity, "normal")
        let model = LibraryModel(database: database)
        try await database.setSensitivity(itemID: stale.id, state: "sensitive")
        do {
            _ = try await model.extractText(from: stale)
            XCTFail("A stale editor must check current classification before accessing a source")
        } catch { XCTAssertTrue(error.localizedDescription.contains("敏感")) }
        do {
            _ = try await model.suggestFacts(file: stale, text: "合成文本", allowedKeys: ["product"])
            XCTFail("Classification must reject before invoking even an unavailable model")
        } catch { XCTAssertTrue(error.localizedDescription.contains("敏感")) }
    }

    func testCancelledReloadDoesNotShowFailureAndNextReloadStillLoadsRealRows() async throws {
        let database = try LibraryDatabase(path: ":memory:")
        try await database.saveSource(id: "cancel-source", name: "取消回归来源",
            path: "/synthetic/cancel-reload", bookmark: Data([1]))
        try database.saveBatch([ScannedFile(relativePath: "订单回归.txt", name: "订单回归.txt",
            typeIdentifier: "public.plain-text", bytes: 12)], sourceID: "cancel-source", scanID: "seed")

        // On the main actor this task cannot start until after cancel(), so this is deterministic.
        // Exercise GRDB's actual cancelled read before the model, without a fake database.
        let read = Task { try await database.queue.read { _ in true } }
        read.cancel()
        do {
            _ = try await read.value
            XCTFail("GRDB should reject a read from an already cancelled task")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let model = LibraryModel(database: database)
        let reload = Task { await model.reload() }
        reload.cancel()
        await reload.value
        XCTAssertNil(model.errorMessage)

        await model.reload()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.sources.map(\.id), ["cancel-source"])
        XCTAssertEqual(model.files.map(\.name), ["订单回归.txt"])
        XCTAssertEqual(model.files.first?.sourceID, "cancel-source")
        XCTAssertEqual(model.total, 1)
    }
    func testRenamingExistingActionPreservesReminderAndShowsCurrentSaveMessage() async throws {
        let database = try LibraryDatabase(path: ":memory:")
        let old = ActionDraft(id: "legacy-single", title: "旧行动", remindAt: Date(timeIntervalSince1970: 1_900_000_000), state: "active", dateConfirmed: true)
        try await database.saveMatter(MatterDraft(id: "legacy", title: "旧单行动事务", actions: [old]))
        let model = LibraryModel(database: database)
        model.reminderMessage = "行动已取消，系统提醒已取消。"
        var edited = old
        edited.title = "修改标题"
        let result = await model.saveAction(edited, matterID: "legacy")
        let saved = try await database.action(id: edited.id)
        XCTAssertTrue(result)
        XCTAssertEqual(saved?.remindAt, old.remindAt)
        XCTAssertEqual(saved?.state, "active")
        XCTAssertEqual(model.reminderMessage, "行动已保存，原提醒保持不变。")
    }

}
