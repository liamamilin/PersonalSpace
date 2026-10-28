import XCTest
@testable import PersonalSpace

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
