import Foundation

struct WebToolActivity: Codable, Sendable {
    var id: Int64
    var requestID: Int64?
    var startedAt: Date
    var tool: String
    var source: String
    var resource: String
    var host: String?
    var durationSeconds: Double
    var resultCount: Int?
    var responseBytes: Int?
    var state: String
    var error: String?
}

struct WebToolSummary: Codable, Sendable {
    var totalRequests: Int
    var successfulRequests: Int
    var failedRequests: Int
    var searchRequests: Int
    var fetchRequests: Int
    var responseBytes: Int
    var recent: [WebToolActivity]
}

actor WebToolMonitor {
    private let limit: Int
    private let store: StatsStore

    init(store: StatsStore, limit: Int = 50) {
        self.store = store
        self.limit = limit
    }

    func record(
        requestID: Int64? = nil, startedAt: Date, tool: String, source: String, resource: String,
        resultCount: Int? = nil, responseBytes: Int? = nil, error: Error? = nil
    ) async {
        let errorDescription = error.map { String(describing: $0) }
        _ = try? await store.recordWebTool(
            requestID: requestID, startedAt: startedAt, tool: tool, source: source,
            resource: resource, resultCount: resultCount, responseBytes: responseBytes,
            error: errorDescription
        )
    }

    func snapshot() async throws -> WebToolSummary {
        try await store.webToolSummary(limit: limit)
    }
}
