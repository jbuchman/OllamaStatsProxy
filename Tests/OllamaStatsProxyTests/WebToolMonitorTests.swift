import Foundation
import Testing
@testable import OllamaStatsProxy

@Test func webToolMonitorTracksResourcesAndTotalsBeyondRecentLimit() async {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("ollama-web-tools-\(UUID().uuidString).sqlite").path
    let store = try! StatsStore(path: path)
    let monitor = WebToolMonitor(store: store, limit: 2)
    let requestID = try! await store.begin(metadata: RequestMetadata(
        model: "test", endpoint: "/api/chat", temperature: nil,
        contextLength: nil, thinkingEnabled: nil, benchmarkLabel: nil
    ))
    await monitor.record(
        requestID: requestID, startedAt: Date(), tool: "search", source: "llm",
        resource: "swift actor monitoring", resultCount: 3
    )
    await monitor.record(
        startedAt: Date(), tool: "fetch", source: "endpoint",
        resource: "https://example.com/docs", responseBytes: 512
    )
    await monitor.record(
        startedAt: Date(), tool: "fetch", source: "llm",
        resource: "not a url", error: WebToolError.badURL
    )

    let snapshot = try! await monitor.snapshot()
    #expect(snapshot.totalRequests == 3)
    #expect(snapshot.successfulRequests == 2)
    #expect(snapshot.failedRequests == 1)
    #expect(snapshot.searchRequests == 1)
    #expect(snapshot.fetchRequests == 2)
    #expect(snapshot.responseBytes == 512)
    #expect(snapshot.recent.count == 2)
    #expect(snapshot.recent.first?.resource == "not a url")
    let persisted = try! await store.allWebToolCalls()
    #expect(persisted.count == 3)
    #expect(persisted[0].requestID == requestID)
    #expect(persisted[1].source == "endpoint")
    #expect(persisted[1].responseBytes == 512)
}
