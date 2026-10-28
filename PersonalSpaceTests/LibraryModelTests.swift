import GRDB
import XCTest
@testable import PersonalSpace

@MainActor
final class LibraryModelTests: XCTestCase {
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
}
