import AsyncHTTPClient
import Foundation
import NIOCore

enum OllamaClientError: Error, CustomStringConvertible {
    case upstreamStatus(Int, String)

    var description: String {
        switch self {
        case .upstreamStatus(let status, let message):
            return message.isEmpty ? "Ollama returned HTTP \(status)" : "Ollama returned HTTP \(status): \(message)"
        }
    }
}

private struct ModelKeepAlivePayload: Encodable {
    var model: String
    var prompt = ""
    var stream = false
    var keepAlive: String

    enum CodingKeys: String, CodingKey {
        case model, prompt, stream
        case keepAlive = "keep_alive"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(stream, forKey: .stream)
        if let numericKeepAlive = Int(keepAlive) {
            try container.encode(numericKeepAlive, forKey: .keepAlive)
        } else {
            try container.encode(keepAlive, forKey: .keepAlive)
        }
    }
}

struct OllamaStatus: Sendable {
    var reachable: Bool
    var version: String?
    var models: [LoadedModel]
    var installedModels: [InstalledModel]
}

struct OllamaClient: Sendable {
    let httpClient: HTTPClient
    let upstream: String

    func status() async -> OllamaStatus {
        do {
            async let versionData = get("/api/version")
            async let modelsData = get("/api/ps")
            async let tagsData = try? get("/api/tags")
            let versionObject = try JSONSerialization.jsonObject(with: await versionData) as? [String: Any]
            let modelsObject = try JSONSerialization.jsonObject(with: await modelsData) as? [String: Any]
            let tagsObject = try (await tagsData).flatMap {
                try JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            let models = (modelsObject?["models"] as? [[String: Any]] ?? []).map { item in
                let size = (item["size"] as? NSNumber)?.int64Value ?? 0
                let vram = (item["size_vram"] as? NSNumber)?.int64Value ?? 0
                return LoadedModel(
                    name: item["name"] as? String ?? "?", size: size, sizeVRAM: vram,
                    gpuPercent: size > 0 ? Int((Double(vram) / Double(size) * 100).rounded()) : 0,
                    contextLength: (item["context_length"] as? NSNumber)?.intValue,
                    quantization: (item["details"] as? [String: Any])?["quantization_level"] as? String,
                    expiresAt: item["expires_at"] as? String, keepAlive: nil
                )
            }
            let installedModels = (tagsObject?["models"] as? [[String: Any]] ?? []).map { item in
                let details = item["details"] as? [String: Any]
                return InstalledModel(
                    name: item["name"] as? String ?? "?",
                    size: (item["size"] as? NSNumber)?.int64Value ?? 0,
                    parameterSize: details?["parameter_size"] as? String,
                    quantization: details?["quantization_level"] as? String
                )
            }
            return OllamaStatus(
                reachable: true, version: versionObject?["version"] as? String,
                models: models, installedModels: installedModels
            )
        } catch {
            return OllamaStatus(reachable: false, version: nil, models: [], installedModels: [])
        }
    }

    func setKeepAlive(model: String, keepAlive: String) async throws {
        var request = HTTPClientRequest(url: upstream + "/api/generate")
        request.method = .POST
        request.headers.add(name: "content-type", value: "application/json")
        request.body = .bytes(ByteBuffer(bytes: try JSONEncoder().encode(
            ModelKeepAlivePayload(model: model, keepAlive: keepAlive)
        )))
        let response = try await httpClient.execute(request, timeout: .seconds(600))
        let responseBody = try await response.body.collect(upTo: 16 * 1024 * 1024)
        guard response.status.code >= 200 && response.status.code < 300 else {
            let message = String(decoding: responseBody.readableBytesView, as: UTF8.self)
            throw OllamaClientError.upstreamStatus(Int(response.status.code), message)
        }
    }

    private func get(_ path: String) async throws -> Data {
        let response = try await httpClient.execute(HTTPClientRequest(url: upstream + path), timeout: .seconds(3))
        let body = try await response.body.collect(upTo: 16 * 1024 * 1024)
        return Data(body.readableBytesView)
    }
}
