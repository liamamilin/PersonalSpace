import Foundation

enum AssistantJSON: Codable, Sendable, Equatable {
    case object([String: AssistantJSON]), array([AssistantJSON]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let object = try? value.decode([String: AssistantJSON].self) { self = .object(object) }
        else if let array = try? value.decode([AssistantJSON].self) { self = .array(array) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else { self = .number(try value.decode(Double.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .string(let string): try value.encode(string)
        case .number(let number): try value.encode(number)
        case .bool(let bool): try value.encode(bool)
        case .null: try value.encodeNil()
        }
    }

    var object: [String: AssistantJSON] { if case .object(let value) = self { value } else { [:] } }
    var array: [AssistantJSON] { if case .array(let value) = self { value } else { [] } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var bool: Bool { if case .bool(let value) = self { value } else { false } }
    subscript(_ key: String) -> AssistantJSON { object[key] ?? .null }
    var encoded: String { String(data: (try? JSONEncoder().encode(self)) ?? Data(), encoding: .utf8) ?? "null" }
    static func date(_ date: Date?) -> AssistantJSON { date.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null }
}

struct AssistantToolCall: Codable, Sendable {
    struct Function: Codable, Sendable {
        var index: Int?
        let name: String
        let arguments: AssistantJSON
    }
    var id: String?
    let function: Function
    private enum CodingKeys: String, CodingKey { case id, type, function }
    init(id: String? = nil, function: Function) { self.id = id; self.function = function }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        function = try c.decode(Function.self, forKey: .function)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode("function", forKey: .type)
        try c.encode(function, forKey: .function)
    }
}

struct AssistantMessage: Codable, Sendable {
    var role: String
    var content: String
    var tool_calls: [AssistantToolCall]?
    var tool_name: String?
    var tool_call_id: String?
    var thinking: String?
}

struct AssistantStreamUpdate: Sendable {
    let content: String
    let thinkingCharacters: Int
    let toolNames: [String]
}

// Ollama sends NDJSON deltas. Keep tool calls private until a complete done frame.
struct AssistantStreamAccumulator {
    private(set) var message = AssistantMessage(role: "assistant", content: "")
    private(set) var done = false

    mutating func append(_ line: String) throws {
        struct Chunk: Decodable {
            struct Delta: Decodable {
                var content: String?
                var thinking: String?
                var tool_calls: [AssistantToolCall]?
            }
            var message: Delta?
            var done: Bool?
            var done_reason: String?
            var error: String?
        }
        guard !done else { return }
        let chunk = try JSONDecoder().decode(Chunk.self, from: Data(line.utf8))
        if chunk.error != nil { throw AssistantError.message("本机模型返回错误，本轮未完成。") }
        message.content += chunk.message?.content ?? ""
        if let thought = chunk.message?.thinking { message.thinking = (message.thinking ?? "") + thought }
        for call in chunk.message?.tool_calls ?? [] {
            guard case .object = call.function.arguments else { throw AssistantError.message("模型返回了不完整工具参数，未执行本段操作。") }
            var calls = message.tool_calls ?? []
            let index = calls.firstIndex {
                if let id = call.id { return $0.id == id }
                return call.function.index != nil && $0.function.index == call.function.index && ($0.function.name == call.function.name || call.function.name.isEmpty)
            }
            if let index {
                let previous = calls[index]
                let arguments = previous.function.arguments.object.merging(call.function.arguments.object) { _, new in new }
                calls[index] = AssistantToolCall(id: call.id ?? previous.id,
                    function: .init(index: call.function.index ?? previous.function.index,
                        name: call.function.name.isEmpty ? previous.function.name : call.function.name,
                        arguments: .object(arguments)))
            } else { calls.append(call) }
            message.tool_calls = calls
        }
        if chunk.done == true {
            guard chunk.done_reason != "length" else { throw AssistantError.message("模型输出达到长度限制，回复尚未完成；未执行本段工具请求。") }
            for call in message.tool_calls ?? [] {
                guard case .object = call.function.arguments, !call.function.name.isEmpty else {
                    throw AssistantError.message("模型没有返回完整工具参数，未执行本段操作。")
                }
            }
            done = true
        }
    }

    var update: AssistantStreamUpdate {
        AssistantStreamUpdate(content: message.content, thinkingCharacters: message.thinking?.count ?? 0,
                              toolNames: (message.tool_calls ?? []).map(\.function.name))
    }

    func completedMessage() throws -> AssistantMessage {
        guard done else { throw AssistantError.message("模型连接中断，回复未完成；未执行本段工具请求。") }
        return message
    }
}

struct AssistantLocalModel: Decodable, Identifiable, Sendable {
    let name: String
    var remote_model: String?
    var remote_host: String?
    var capabilities: [String]?
    var id: String { name }
    var isLocal: Bool { remote_model == nil && remote_host == nil && !name.lowercased().contains(":cloud") }
}

struct AssistantClient: Sendable {
    private let base = URL(string: "http://127.0.0.1:11434")!

    func models() async throws -> [AssistantLocalModel] {
        struct List: Decodable { let models: [AssistantLocalModel] }
        let data = try await request(path: "api/tags")
        let list = try JSONDecoder().decode(List.self, from: data)
        var available: [AssistantLocalModel] = []
        for var model in list.models where model.isLocal {
            if model.capabilities == nil {
                let body = AssistantJSON.object(["model": .string(model.name)])
                let detail = try JSONDecoder().decode(AssistantJSON.self, from: await request(path: "api/show", body: body))
                model.capabilities = detail["capabilities"].array.compactMap(\.string)
            }
            if model.capabilities?.contains("tools") == true && model.capabilities?.contains("completion") == true {
                available.append(model)
            }
        }
        return available.sorted { $0.name < $1.name }
    }

    func chat(model: String, messages: [AssistantMessage], tools: AssistantJSON, thinking: Bool = false,
              onUpdate: @escaping @MainActor @Sendable (AssistantStreamUpdate) -> Void) async throws -> AssistantMessage {
        struct Request: Encodable {
            let model: String
            let messages: [AssistantMessage]
            let tools: AssistantJSON
            let stream = true
            let think: Bool
            let options: AssistantJSON = .object(["temperature": .number(0), "num_ctx": .number(16_384)])
        }
        var request = URLRequest(url: base.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(model: model, messages: messages, tools: tools, think: thinking))
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw AssistantError.message("本机模型请求失败，请检查 Ollama 和所选模型。")
            }
            var stream = AssistantStreamAccumulator()
            var lastUpdate = ContinuousClock.now
            var first = true
            for try await line in bytes.lines where !line.isEmpty {
                try Task.checkCancellation()
                try stream.append(line)
                // Coalesce very small chunks without delaying the first visible data.
                if first || stream.done || lastUpdate.duration(to: .now) >= .milliseconds(70) {
                    await onUpdate(stream.update)
                    first = false
                    lastUpdate = .now
                }
                if stream.done { break }
            }
            return try stream.completedMessage()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let error = error as? AssistantError { throw error }
            if (error as? URLError)?.code == .timedOut { throw AssistantError.message("本机模型响应超时，已收到的文字会保留；本段工具请求未执行。") }
            throw AssistantError.message("本机模型连接中断，已收到的文字会保留；请检查 Ollama 后重试。")
        }
    }

    private func request(path: String, body: AssistantJSON? = nil) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.timeoutInterval = body == nil ? 10 : 180
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw AssistantError.message("本机模型请求失败，请检查 Ollama 和所选模型。")
            }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as AssistantError { throw error }
        catch {
            if Task.isCancelled { throw CancellationError() }
            if (error as? URLError)?.code == .timedOut { throw AssistantError.message("本机模型响应超时。请缩短请求或选择更快的本机模型后重试。") }
            throw AssistantError.message("无法连接本机 Ollama。请打开 Ollama 后重试，手动功能仍可使用。")
        }
    }
}

enum AssistantError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let message): message } }
}
