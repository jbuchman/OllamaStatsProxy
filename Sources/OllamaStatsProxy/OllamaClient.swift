import AsyncHTTPClient
import Foundation
import NIOCore

struct OllamaStatus: Sendable {
    var reachable: Bool
    var version: String?
    var models: [LoadedModel]
}

struct OllamaClient: Sendable {
    let httpClient: HTTPClient
    let upstream: String

    func status() async -> OllamaStatus {
        do {
            async let versionData = get("/api/version")
            async let modelsData = get("/api/ps")
            let versionObject = try JSONSerialization.jsonObject(with: await versionData) as? [String: Any]
            let modelsObject = try JSONSerialization.jsonObject(with: await modelsData) as? [String: Any]
            let models = (modelsObject?["models"] as? [[String: Any]] ?? []).map { item in
                let size = (item["size"] as? NSNumber)?.int64Value ?? 0
                let vram = (item["size_vram"] as? NSNumber)?.int64Value ?? 0
                return LoadedModel(
                    name: item["name"] as? String ?? "?", size: size, sizeVRAM: vram,
                    gpuPercent: size > 0 ? Int((Double(vram) / Double(size) * 100).rounded()) : 0,
                    contextLength: (item["context_length"] as? NSNumber)?.intValue,
                    quantization: (item["details"] as? [String: Any])?["quantization_level"] as? String,
                    expiresAt: item["expires_at"] as? String
                )
            }
            return OllamaStatus(reachable: true, version: versionObject?["version"] as? String, models: models)
        } catch {
            return OllamaStatus(reachable: false, version: nil, models: [])
        }
    }

    private func get(_ path: String) async throws -> Data {
        let response = try await httpClient.execute(HTTPClientRequest(url: upstream + path), timeout: .seconds(3))
        let body = try await response.body.collect(upTo: 16 * 1024 * 1024)
        return Data(body.readableBytesView)
    }
}
