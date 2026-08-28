import AsyncHTTPClient
import Foundation
import NIOCore

struct LangflowClient: Sendable {
    let client: HTTPClient
    let configuration: ConfigurationFile

    func virtualModel(named requestedName: String) async -> VirtualModel? {
        let config = await configuration.value()
        return (config.virtualModels ?? []).first {
            $0.enabled && $0.name.caseInsensitiveCompare(requestedName) == .orderedSame
        }
    }

    func chat(model: VirtualModel, ollamaBody: Data) async throws -> Data {
        let object = try JSONSerialization.jsonObject(with: ollamaBody) as? [String: Any] ?? [:]
        let text = try await runWorkflow(model: model, requestObject: object)
        return try Self.ollamaResponse(
            model: model.name,
            text: text,
            stream: object["stream"] as? Bool ?? true
        )
    }

    func openAIChat(model: VirtualModel, body: Data) async throws -> Data {
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
        let text = try await runWorkflow(model: model, requestObject: object)
        return try Self.openAIResponse(
            model: model.name,
            text: text,
            stream: object["stream"] as? Bool ?? false
        )
    }

    private func runWorkflow(model: VirtualModel, requestObject object: [String: Any]) async throws -> String {
        let config = await configuration.value()
        guard let base = config.langflowURL?.trimmingCharacters(in: CharacterSet(charactersIn: "/")), !base.isEmpty else {
            throw LangflowError.notConfigured
        }
        let messages = object["messages"] as? [[String: Any]] ?? []
        let latestUser = messages.reversed().first { ($0["role"] as? String) == "user" }?["content"] as? String ?? ""
        // Preserve Langflow conversational state even for clients (such as many
        // OpenAI-compatible front ends) that do not send an explicit session id.
        // An explicit session_id/user always wins; otherwise the virtual model
        // gets a stable proxy-owned session rather than a new UUID every turn.
        let sessionID = (object["session_id"] as? String)?.nilIfEmpty
            ?? (object["user"] as? String)?.nilIfEmpty
            ?? "ollama-stats-proxy:virtual-model:\(model.name.lowercased())"
        let payload: [String: Any] = [
            "flow_id": model.flowID,
            "input_value": latestUser,
            "session_id": sessionID,
            "mode": "sync"
        ]
        var request = HTTPClientRequest(url: base + "/api/v2/workflows")
        request.method = .POST
        request.headers.add(name: "content-type", value: "application/json")
        if let key = config.langflowAPIKey, !key.isEmpty { request.headers.add(name: "x-api-key", value: key) }
        request.body = .bytes(ByteBuffer(bytes: try JSONSerialization.data(withJSONObject: payload)))
        let response = try await client.execute(request, timeout: .hours(24))
        let body = try await response.body.collect(upTo: 64 * 1024 * 1024)
        let data = Data(body.readableBytesView)
        guard (200..<300).contains(Int(response.status.code)) else {
            throw LangflowError.http(Int(response.status.code), String(data: data, encoding: .utf8) ?? "")
        }
        let json = try JSONSerialization.jsonObject(with: data)
        guard let text = Self.findText(json), !text.isEmpty else { throw LangflowError.missingOutput }
        return text
    }

    private static func findText(_ value: Any) -> String? {
        if let dict = value as? [String: Any] {
            if let output = dict["output"] as? [String: Any], let text = output["text"] as? String { return text }
            if let text = dict["text"] as? String { return text }
            for key in ["output", "result", "outputs"] { if let v = dict[key], let found = findText(v) { return found } }
        } else if let array = value as? [Any] {
            for item in array { if let found = findText(item) { return found } }
        }
        return nil
    }

    private static func ollamaResponse(model: String, text: String, stream: Bool) throws -> Data {
        let created = ISO8601DateFormatter().string(from: Date())
        if !stream {
            return try JSONSerialization.data(withJSONObject: [
                "model": model, "created_at": created,
                "message": ["role": "assistant", "content": text], "done": true
            ])
        }
        let first = try JSONSerialization.data(withJSONObject: [
            "model": model, "created_at": created,
            "message": ["role": "assistant", "content": text], "done": false
        ])
        let final = try JSONSerialization.data(withJSONObject: [
            "model": model, "created_at": created,
            "message": ["role": "assistant", "content": ""], "done": true
        ])
        return first + Data([0x0A]) + final + Data([0x0A])
    }

    private static func openAIResponse(model: String, text: String, stream: Bool) throws -> Data {
        let created = Int(Date().timeIntervalSince1970)
        let id = "chatcmpl-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        if !stream {
            return try JSONSerialization.data(withJSONObject: [
                "id": id,
                "object": "chat.completion",
                "created": created,
                "model": model,
                "choices": [[
                    "index": 0,
                    "message": ["role": "assistant", "content": text],
                    "finish_reason": "stop"
                ]],
                "usage": ["prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0]
            ])
        }

        let first = try JSONSerialization.data(withJSONObject: [
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [[
                "index": 0,
                "delta": ["role": "assistant", "content": text],
                "finish_reason": NSNull()
            ]]
        ])
        let final = try JSONSerialization.data(withJSONObject: [
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [[
                "index": 0,
                "delta": [:] as [String: Any],
                "finish_reason": "stop"
            ]]
        ])
        var result = Data("data: ".utf8)
        result.append(first)
        result.append(Data("\n\ndata: ".utf8))
        result.append(final)
        result.append(Data("\n\ndata: [DONE]\n\n".utf8))
        return result
    }

}

enum LangflowError: Error, CustomStringConvertible {
    case notConfigured, missingOutput, http(Int, String)
    var description: String {
        switch self {
        case .notConfigured: "Langflow URL is not configured"
        case .missingOutput: "Langflow workflow returned no text output"
        case .http(let status, let body): "Langflow HTTP \(status): \(body)"
        }
    }
}
