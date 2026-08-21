import AsyncHTTPClient
import HummingbirdCore
import Foundation
import HTTPTypes
import NIOCore

struct ToolOrchestrator: Sendable {
    enum EndpointKind: Sendable {
        case openAI
        case ollama

        static func from(path: String) -> EndpointKind? {
            switch path {
            case "/v1/chat/completions": .openAI
            case "/api/chat": .ollama
            default: nil
            }
        }
    }

    struct Result: @unchecked Sendable {
        let status: Int
        let headers: [(String, String)]
        let body: Data
        let kind: EndpointKind
        let requestedStreaming: Bool
    }

    static let searchToolName = "ollama_proxy_search_web"
    static let fetchToolName = "ollama_proxy_fetch_url"
    static let optionalToolGuidance = "Web search and URL fetching are optional capabilities. Use them only when the request needs current external information or asks you to inspect a web page. For reasoning, coding, writing, or other self-contained requests, answer directly without a tool. The absence of a relevant tool never prevents you from answering normally."

    let upstream: String
    let client: HTTPClient
    let webTools: WebTools
    let configuration: ConfigurationFile

    func shouldHandle(path: String, body: Data) async -> Bool {
        let configuration = await configuration.value()
        guard configuration.serverToolsEnabled,
              configuration.webFetchEnabled != false || configuration.webSearchProvider != nil,
              EndpointKind.from(path: path) != nil,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return false }
        if let explicit = object["ollama_proxy_tools"] as? Bool { return explicit }
        return Self.appearsToNeedWebTools(object)
    }

    func handle(path: String, incomingHeaders: HTTPFields, body: Data, requestID: Int64?) async throws -> Result {
        guard let kind = EndpointKind.from(path: path),
              var requestObject = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { throw OrchestratorError.unsupportedRequest }

        let configuration = await configuration.value()
        let requestedStreaming = (requestObject["stream"] as? Bool) ?? false
        requestObject.removeValue(forKey: "ollama_proxy_tools")
        requestObject["stream"] = false
        requestObject["tools"] = mergeTools(
            requestObject["tools"] as? [[String: Any]] ?? [], configuration: configuration
        )
        addOptionalToolGuidance(to: &requestObject)

        for round in 0...configuration.serverToolRounds {
            let response = try await post(path: path, headers: incomingHeaders, object: requestObject)
            guard (200..<300).contains(response.status),
                  let responseObject = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
            else {
                return Result(status: response.status, headers: response.headers, body: response.body, kind: kind, requestedStreaming: requestedStreaming)
            }

            let calls = toolCalls(from: responseObject, kind: kind)
            let internalCalls = calls.filter { isInternalTool($0.name, configuration: configuration) }
            let externalCalls = calls.filter { !isInternalTool($0.name, configuration: configuration) }

            // Never consume a tool call that belongs to the client. Returning the upstream
            // response here preserves arbitrary client-owned tools without knowing their schema.
            if !externalCalls.isEmpty || internalCalls.isEmpty || round == configuration.serverToolRounds {
                return Result(status: response.status, headers: response.headers, body: response.body, kind: kind, requestedStreaming: requestedStreaming)
            }

            guard var messages = requestObject["messages"] as? [[String: Any]],
                  let assistantMessage = assistantMessage(from: responseObject, kind: kind)
            else { throw OrchestratorError.malformedResponse }

            messages.append(assistantMessage)
            for call in internalCalls {
                let content = await execute(call, requestID: requestID)
                messages.append(toolResultMessage(for: call, content: content, kind: kind))
            }
            requestObject["messages"] = messages
        }

        throw OrchestratorError.tooManyRounds
    }

    func responseBody(for result: Result) -> ResponseBody {
        guard result.requestedStreaming else {
            return .init(byteBuffer: ByteBuffer(bytes: result.body))
        }

        // Server-owned tool orchestration must inspect complete model turns. To remain
        // compatible with streaming clients, replay the completed turn in the protocol's
        // streaming envelope. This is buffered rather than token-live by design.
        switch result.kind {
        case .openAI:
            return .init(byteBuffer: ByteBuffer(bytes: openAIStream(from: result.body)))
        case .ollama:
            var data = result.body
            if data.last != 0x0A { data.append(0x0A) }
            return .init(byteBuffer: ByteBuffer(bytes: data))
        }
    }

    func responseHeaders(for result: Result) -> HTTPFields {
        var fields = HTTPFields()
        for (nameString, value) in result.headers {
            let lower = nameString.lowercased()
            guard !Proxy.hopHeaders.contains(lower), lower != "content-type", lower != "content-length" else { continue }
            if let name = HTTPField.Name(nameString) { fields.append(HTTPField(name: name, value: value)) }
        }
        if result.requestedStreaming {
            fields[.contentType] = result.kind == .openAI ? "text/event-stream" : "application/x-ndjson"
        } else {
            fields[.contentType] = "application/json"
        }
        return fields
    }

    private func mergeTools(_ existing: [[String: Any]], configuration: AppConfiguration) -> [[String: Any]] {
        let existingNames = Set(existing.compactMap(Self.toolName))
        var result = existing
        if configuration.webSearchProvider != nil, !existingNames.contains(Self.searchToolName) {
            result.append(Self.makeSearchToolDefinition())
        }
        if configuration.webFetchEnabled != false, !existingNames.contains(Self.fetchToolName) {
            result.append(Self.makeFetchToolDefinition())
        }
        return result
    }

    static func appearsToNeedWebTools(_ object: [String: Any]) -> Bool {
        guard let messages = object["messages"] as? [[String: Any]],
              let userMessage = messages.last(where: { ($0["role"] as? String) == "user" }),
              let content = textContent(userMessage["content"]), !content.isEmpty else { return false }
        let patterns = [
            #"https?://|www\."#,
            #"\b[a-z0-9-]+\.(com|org|net|io|dev|gov|edu)(/[^\s]*)?\b"#,
            #"\b(search|browse) (the )?(web|internet|online)\b"#,
            #"\b(web search|internet search|search online)\b"#,
            #"\blook .{0,40} up (online|on the web|on the internet)\b"#,
            #"\bfind .{0,40} (online|on the web|on the internet)\b"#,
            #"\b(latest news|recent news|current events|today's news|up-to-date information)\b"#,
            #"\b(cite|provide|include) (your )?(sources|citations)\b"#
        ]
        return patterns.contains { content.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    private static func textContent(_ raw: Any?) -> String? {
        if let text = raw as? String { return text }
        if let parts = raw as? [[String: Any]] {
            return parts.compactMap { part in
                guard (part["type"] as? String) == "text" else { return nil }
                return part["text"] as? String
            }.joined(separator: "\n")
        }
        return nil
    }

    private func addOptionalToolGuidance(to request: inout [String: Any]) {
        guard var messages = request["messages"] as? [[String: Any]] else { return }
        if let firstSystem = messages.firstIndex(where: { ($0["role"] as? String) == "system" }),
           let content = messages[firstSystem]["content"] as? String {
            if !content.contains(Self.optionalToolGuidance) {
                messages[firstSystem]["content"] = content + "\n\n" + Self.optionalToolGuidance
            }
        } else {
            messages.insert(["role": "system", "content": Self.optionalToolGuidance], at: 0)
        }
        request["messages"] = messages
    }

    private func toolCalls(from object: [String: Any], kind: EndpointKind) -> [ToolCall] {
        let message: [String: Any]?
        switch kind {
        case .openAI:
            message = ((object["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any]
        case .ollama:
            message = object["message"] as? [String: Any]
        }
        guard let raw = message?["tool_calls"] as? [[String: Any]] else { return [] }
        return raw.compactMap { ToolCall(object: $0) }
    }

    private func assistantMessage(from object: [String: Any], kind: EndpointKind) -> [String: Any]? {
        switch kind {
        case .openAI:
            return ((object["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any]
        case .ollama:
            return object["message"] as? [String: Any]
        }
    }

    private func toolResultMessage(for call: ToolCall, content: String, kind: EndpointKind) -> [String: Any] {
        switch kind {
        case .openAI:
            return ["role": "tool", "tool_call_id": call.id ?? call.name, "content": content]
        case .ollama:
            // Ollama accepts the OpenAI-style tool_call_id/name fields and ignores fields
            // a particular model template does not use.
            var result: [String: Any] = ["role": "tool", "name": call.name, "content": content]
            if let id = call.id { result["tool_call_id"] = id }
            return result
        }
    }

    private func execute(_ call: ToolCall, requestID: Int64?) async -> String {
        do {
            switch call.name {
            case Self.searchToolName:
                guard let query = call.arguments["query"] as? String, !query.isEmpty else {
                    return Self.jsonString(["error": "missing query"])
                }
                let count = (call.arguments["count"] as? NSNumber)?.intValue ?? 5
                return Self.jsonString(try await webTools.search(query, count: count, source: "llm", requestID: requestID))
            case Self.fetchToolName:
                guard let url = call.arguments["url"] as? String, !url.isEmpty else {
                    return Self.jsonString(["error": "missing url"])
                }
                return Self.jsonString(try await webTools.fetch(url, source: "llm", requestID: requestID))
            default:
                return Self.jsonString(["error": "unknown server tool"])
            }
        } catch {
            return Self.jsonString(["error": String(describing: error)])
        }
    }

    private func post(path: String, headers: HTTPFields, object: [String: Any]) async throws -> RawResponse {
        var request = HTTPClientRequest(url: upstream + path)
        request.method = .POST
        for field in headers where !Proxy.hopHeaders.contains(field.name.canonicalName) {
            request.headers.add(name: field.name.canonicalName, value: field.value)
        }
        request.headers.replaceOrAdd(name: "content-type", value: "application/json")
        request.body = .bytes(ByteBuffer(bytes: try JSONSerialization.data(withJSONObject: object)))
        let response = try await client.execute(request, timeout: .hours(24))
        let body = try await response.body.collect(upTo: 512 * 1024 * 1024)
        return RawResponse(
            status: Int(response.status.code),
            headers: response.headers.map { ($0.name, $0.value) },
            body: Data(body.readableBytesView)
        )
    }

    private func openAIStream(from body: Data) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              var choice = (object["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any]
        else { return Data("data: \(String(decoding: body, as: UTF8.self))\n\ndata: [DONE]\n\n".utf8) }

        choice.removeValue(forKey: "message")
        choice["delta"] = message
        var chunk = object
        chunk["choices"] = [choice]
        let encoded = (try? JSONSerialization.data(withJSONObject: chunk)) ?? body
        return Data("data: \(String(decoding: encoded, as: UTF8.self))\n\ndata: [DONE]\n\n".utf8)
    }

    private static func toolName(_ definition: [String: Any]) -> String? {
        if let function = definition["function"] as? [String: Any] { return function["name"] as? String }
        return definition["name"] as? String
    }

    private func isInternalTool(_ name: String, configuration: AppConfiguration) -> Bool {
        (name == Self.fetchToolName && configuration.webFetchEnabled != false)
            || (name == Self.searchToolName && configuration.webSearchProvider != nil)
    }

    private static func jsonString<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return #"{"error":"encoding failed"}"# }
        return String(decoding: data, as: UTF8.self)
    }

    private static func jsonString(_ value: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return #"{"error":"encoding failed"}"# }
        return String(decoding: data, as: UTF8.self)
    }

    private struct ToolDefinition: Codable, Sendable {
        let type: String
        let function: ToolFunction
    }

    private struct ToolFunction: Codable, Sendable {
        let name: String
        let description: String
        let parameters: ToolParameters
    }

    private struct ToolParameters: Codable, Sendable {
        let type: String
        let properties: [String: Property]
        let required: [String]

        struct Property: Codable, Sendable {
            let type: String
            let description: String
            let minimum: Int?
            let maximum: Int?

            init(type: String, description: String, minimum: Int? = nil, maximum: Int? = nil) {
                self.type = type
                self.description = description
                self.minimum = minimum
                self.maximum = maximum
            }
        }
    }

    private static func encodeToolDefinition(_ def: ToolDefinition) -> [String: Any] {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(def),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    private static func makeSearchToolDefinition() -> [String: Any] {
        let def = ToolDefinition(
            type: "function",
            function: ToolFunction(
                name: searchToolName,
                description: "Search the current web when up-to-date information is needed. Returns titles, URLs, and snippets. Use fetch_url on promising results when full source text is needed.",
                parameters: ToolParameters(
                    type: "object",
                    properties: [
                        "query": .init(type: "string", description: "Search query"),
                        "count": .init(type: "integer", description: "Maximum results to return", minimum: 1, maximum: 10)
                    ],
                    required: ["query"]
                )
            )
        )
        return encodeToolDefinition(def)
    }

    private static func makeFetchToolDefinition() -> [String: Any] {
        let def = ToolDefinition(
            type: "function",
            function: ToolFunction(
                name: fetchToolName,
                description: "Fetch an HTTP or HTTPS URL and return cleaned Markdown with page structure and links preserved. Use exact URLs returned by search_web when inspecting a source.",
                parameters: ToolParameters(
                    type: "object",
                    properties: [
                        "url": .init(type: "string", description: "Absolute HTTP or HTTPS URL")
                    ],
                    required: ["url"]
                )
            )
        )
        return encodeToolDefinition(def)
    }
}

private struct RawResponse: @unchecked Sendable {
    let status: Int
    let headers: [(String, String)]
    let body: Data
}

private struct ToolCall: @unchecked Sendable {
    let id: String?
    let name: String
    let arguments: [String: Any]

    init?(object: [String: Any]) {
        id = object["id"] as? String
        let function = object["function"] as? [String: Any] ?? object
        guard let name = function["name"] as? String else { return nil }
        self.name = name
        if let dictionary = function["arguments"] as? [String: Any] {
            arguments = dictionary
        } else if let string = function["arguments"] as? String,
                  let data = string.data(using: .utf8),
                  let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            arguments = dictionary
        } else {
            arguments = [:]
        }
    }
}

enum OrchestratorError: Error {
    case unsupportedRequest
    case malformedResponse
    case tooManyRounds
}
