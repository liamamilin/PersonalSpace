import XCTest
@testable import PersonalSpace

@MainActor
final class AssistantTests: XCTestCase {
    func testStreamingAccumulatesTextAndToolsWithoutPublishingIncompleteCalls() throws {
        var stream = AssistantStreamAccumulator()
        try stream.append(#"{"message":{"thinking":"local reasoning"},"done":false}"#)
        XCTAssertEqual(stream.update.thinkingCharacters, 15)
        try stream.append(#"{"message":{"content":"正在查询"},"done":false}"#)
        try stream.append(#"{"message":{"content":"资料。","tool_calls":[{"id":"one","function":{"index":0,"name":"search_library","arguments":{"entity":"files"}}}]},"done":false}"#)
        XCTAssertEqual(stream.update.content, "正在查询资料。")
        XCTAssertThrowsError(try stream.completedMessage())
        try stream.append(#"{"message":{"tool_calls":[{"id":"one","function":{"index":0,"name":"search_library","arguments":{"query":"电脑"}}},{"id":"two","function":{"index":1,"name":"library_info","arguments":{}}}]},"done":false}"#)
        try stream.append(#"{"done":true,"done_reason":"stop"}"#)
        let message = try stream.completedMessage()
        XCTAssertEqual(message.tool_calls?.count, 2)
        XCTAssertEqual(message.tool_calls?.first?.function.arguments["entity"].string, "files")
        XCTAssertEqual(message.tool_calls?.first?.function.arguments["query"].string, "电脑")
        XCTAssertEqual(message.content, "正在查询资料。")
        XCTAssertEqual(message.thinking, "local reasoning")
    }

    func testBrokenOrTruncatedStreamsNeverReturnExecutableTools() throws {
        var interrupted = AssistantStreamAccumulator()
        try interrupted.append(#"{"message":{"content":"部分回复","tool_calls":[{"function":{"name":"object_operation","arguments":{"operation":"create","name":"未完成"}}}]},"done":false}"#)
        XCTAssertEqual(interrupted.update.content, "部分回复")
        XCTAssertThrowsError(try interrupted.completedMessage())
        XCTAssertThrowsError(try interrupted.append(#"{"done":true,"done_reason":"length"}"#))
        XCTAssertThrowsError(try interrupted.completedMessage())
        var failed = AssistantStreamAccumulator()
        XCTAssertThrowsError(try failed.append(#"{"error":"synthetic runtime failure"}"#))
        XCTAssertThrowsError(try failed.completedMessage())
        var invalidArguments = AssistantStreamAccumulator()
        XCTAssertThrowsError(try invalidArguments.append(#"{"message":{"tool_calls":[{"function":{"name":"object_operation","arguments":"{unfinished"}}]},"done":true}"#))
        XCTAssertThrowsError(try invalidArguments.completedMessage())
    }

    private func call(_ name: String, _ arguments: [String: AssistantJSON] = [:]) -> AssistantToolCall {
        AssistantToolCall(function: .init(name: name, arguments: .object(arguments)))
    }

    private func database() async throws -> LibraryDatabase {
        let db = try LibraryDatabase(path: ":memory:")
        try await db.saveSource(id: "synthetic", name: "合成来源", path: "/synthetic", bookmark: Data([1]))
        try db.saveBatch((0..<4).map { ScannedFile(relativePath: "订单\($0).txt", name: "订单\($0).txt", typeIdentifier: "public.plain-text", bytes: 10) }, sourceID: "synthetic", scanID: "test")
        return db
    }

    func testObjectToolsSaveRealLinksAndFileSearchPaginates() async throws {
        let db = try await database()
        let model = LibraryModel(database: db)
        let assistant = AssistantController(library: model)
        let created = try await assistant.execute(call("object_operation", ["operation": .string("create"), "name": .string("我的电脑")]))
        let objectID = try XCTUnwrap(created.value["id"].string)
        let first = try await assistant.execute(call("search_library", ["entity": .string("files"), "limit": .number(2)]))
        let second = try await assistant.execute(call("search_library", ["entity": .string("files"), "limit": .number(2), "offset": .number(2)]))
        let firstIDs = first.value["results"].array.compactMap { $0["id"].string }
        let secondIDs = second.value["results"].array.compactMap { $0["id"].string }
        XCTAssertEqual(firstIDs.count, 2)
        XCTAssertTrue(Set(firstIDs).isDisjoint(with: secondIDs))
        let bounded = try await assistant.execute(call("search_library", ["entity": .string("files"), "limit": .number(1e30), "offset": .number(1e30)]))
        XCTAssertTrue(bounded.value["results"].array.isEmpty)
        _ = try await assistant.execute(call("object_operation", ["operation": .string("link"), "object_id": .string(objectID), "item_ids": .array(firstIDs.map(AssistantJSON.string))]))
        let links = try await db.files(FileQuery(objectID: objectID))
        XCTAssertEqual(Set(links.files.map(\.id)), Set(firstIDs))
        let inspect = try await assistant.execute(call("inspect_file", ["item_id": .string(firstIDs[0])]))
        XCTAssertEqual(inspect.value["objects"].array.first?["id"].string, objectID)
        _ = try await assistant.execute(call("object_operation", ["operation": .string("update"), "object_id": .string(objectID), "notes": .string("更新备注")]))
        let saved = try await db.objects().first
        XCTAssertEqual(saved?.name, "我的电脑")
        XCTAssertEqual(saved?.notes, "更新备注")
        XCTAssertEqual(saved?.itemCount, 2)
    }

    func testMatterAndReminderProposalsRequireReviewAndKeepOtherActions() async throws {
        let db = try await database()
        let library = LibraryModel(database: db)
        let assistant = AssistantController(library: library)
        let future = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 86_400)
        let a = ActionDraft(title: "检查 A", remindAt: future, state: "active", dateConfirmed: true)
        let b = ActionDraft(title: "检查 B", remindAt: future.addingTimeInterval(3_600), state: "active", dateConfirmed: true)
        let original = MatterDraft(title: "合成保修", facts: [FactDraft(key: "product", valueText: "旧名称", state: "confirmed")], actions: [a, b])
        try await db.saveMatter(original)
        let proposal = try await assistant.execute(call("prepare_matter", ["matter_id": .string(original.id), "title": .string("新标题"),
            "facts": .object(["product": .string("待核对名称")]), "actions": .array([.object(["title": .string("新行动"), "remind_at": .string(ISO8601DateFormatter().string(from: future))])])]))
        XCTAssertTrue(proposal.needsUserInput)
        XCTAssertEqual(library.matterDraft.actions.count, 3)
        XCTAssertEqual(library.matterDraft.actions.first(where: { $0.id == b.id }), b)
        XCTAssertEqual(library.matterDraft.facts.first?.state, "candidate")
        XCTAssertEqual(library.matterDraft.facts.first?.origin, "model")
        XCTAssertFalse(try XCTUnwrap(library.matterDraft.actions.last).dateConfirmed)
        let stored = try await db.matter(id: original.id)
        let storedActions = try await db.actions(matterID: original.id)
        XCTAssertEqual(stored?.title, "合成保修")
        XCTAssertEqual(storedActions.count, 2)
        _ = try await assistant.execute(call("action_operation", ["operation": .string("complete"), "action_id": .string(a.id)]))
        let afterA = try await db.action(id: a.id), afterB = try await db.action(id: b.id)
        XCTAssertEqual(afterA?.state, "done")
        XCTAssertEqual(afterB?.state, "active")
        XCTAssertEqual(afterB?.remindAt, b.remindAt)
    }

    func testSensitiveBodyAndUnknownIDsAreRejectedAndLocalModelDecodeIsReal() async throws {
        let db = try await database()
        let assistant = AssistantController(library: LibraryModel(database: db))
        let files = try await db.files(FileQuery()).files
        let item = try XCTUnwrap(files.first)
        try await db.setSensitivity(itemID: item.id, state: "sensitive")
        do {
            _ = try await assistant.execute(call("inspect_file", ["item_id": .string(item.id), "read_body": .bool(true)]))
            XCTFail("Sensitive body must not reach the model")
        } catch { }
        do {
            _ = try await assistant.execute(call("prepare_matter", ["title": .string("拒绝敏感识别"), "recognize_item_id": .string(item.id)]))
            XCTFail("Sensitive content must also be refused by native recognition")
        } catch { }
        do {
            _ = try await assistant.execute(call("inspect_file", ["item_id": .string("invented-id")]))
            XCTFail("Invented IDs must fail")
        } catch { }
        let json = #"{"role":"assistant","content":"","thinking":"synthetic local reasoning","tool_calls":[{"id":"local-call","function":{"name":"library_info","arguments":{}}}]}"#
        let message = try JSONDecoder().decode(AssistantMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.tool_calls?.first?.function.name, "library_info")
        XCTAssertEqual(message.thinking, "synthetic local reasoning")
        let encoded = try JSONDecoder().decode(AssistantJSON.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(encoded["tool_calls"].array.first?["type"].string, "function")
        XCTAssertEqual(encoded["tool_calls"].array.first?["id"].string, "local-call")
        let cloud = try JSONDecoder().decode(AssistantLocalModel.self, from: Data(#"{"name":"test:cloud","remote_host":"https://example.invalid"}"#.utf8))
        XCTAssertFalse(cloud.isLocal)
    }
}
