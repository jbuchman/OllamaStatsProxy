import Foundation
import GRDB

struct RequestMetadata: Sendable {
    var model: String
    var endpoint: String
    var temperature: Double?
    var contextLength: Int?
    var thinkingEnabled: Bool?
    var benchmarkLabel: String?
}

struct RequestRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "requests"

    var id: Int64?
    var model: String
    var endpoint: String
    var startedAt: Date
    var endedAt: Date?
    var promptTokens: Int
    var outputTokens: Int
    var firstTokenAt: Date?
    var totalDurationNanoseconds: Int64?
    var loadDurationNanoseconds: Int64?
    var promptEvalDurationNanoseconds: Int64?
    var evalDurationNanoseconds: Int64?
    var temperature: Double?
    var contextLength: Int?
    var thinkingEnabled: Bool?
    var benchmarkLabel: String?
    var resourceSampleCount: Int
    var averageCPUPercent: Double?
    var averageMemoryUsedBytes: Int64?
    var error: String?

    var elapsedSeconds: Double {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var averageTokensPerSecond: Double {
        if let evalDurationNanoseconds, evalDurationNanoseconds > 0 {
            return Double(outputTokens) / (Double(evalDurationNanoseconds) / 1_000_000_000)
        }
        return elapsedSeconds > 0 ? Double(outputTokens) / elapsedSeconds : 0
    }

    var timeToFirstTokenSeconds: Double? { firstTokenAt?.timeIntervalSince(startedAt) }
    var promptTokensPerSecond: Double? {
        guard let duration = promptEvalDurationNanoseconds, duration > 0 else { return nil }
        return Double(promptTokens) / (Double(duration) / 1_000_000_000)
    }
}

struct WebToolRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "webToolCalls"

    var id: Int64?
    var requestID: Int64?
    var startedAt: Date
    var endedAt: Date
    var tool: String
    var source: String
    var resource: String
    var host: String?
    var resultCount: Int?
    var responseBytes: Int?
    var error: String?

    var durationSeconds: Double { endedAt.timeIntervalSince(startedAt) }
}

struct RequestSnapshot: Codable, Sendable {
    var id: Int64
    var model: String
    var endpoint: String
    var startedAt: Date
    var endedAt: Date?
    var promptTokens: Int
    var outputTokens: Int
    var elapsedSeconds: Double
    var tokensPerSecond: Double
    var timeToFirstTokenSeconds: Double?
    var promptTokensPerSecond: Double?
    var totalDurationSeconds: Double?
    var loadDurationSeconds: Double?
    var temperature: Double?
    var contextLength: Int?
    var thinkingEnabled: Bool?
    var benchmarkLabel: String?
    var resourceSampleCount: Int
    var averageCPUPercent: Double?
    var averageMemoryUsedBytes: Int64?
    var state: String
    var error: String?
}

struct BenchmarkSummary: Codable, Sendable, FetchableRecord {
    var model: String
    var runs: Int
    var averageOutputTokensPerSecond: Double
    var averagePromptTokensPerSecond: Double?
    var averageTimeToFirstTokenSeconds: Double?
    var averageTotalDurationSeconds: Double
    var averageCPUPercent: Double?
    var averageMemoryUsedBytes: Double?
}

struct TokenSummary: Codable, Sendable {
    var outputTokens: Int
    var promptTokens: Int
    var requests: Int
    var liveTokensPerSecond: Double
}

struct ProcessStats: Codable, Sendable {
    var pid: Int
    var kind: String
    var cpuPercent: Double
    var threads: Int
    var residentBytes: Int64
}

struct SystemStats: Codable, Sendable {
    var cpuPercent: Double?
    var coreCount: Int
    var loadAverage: [Double]
    var memoryUsedBytes: Int64?
    var memoryTotalBytes: Int64?
    var ollamaProcesses: [ProcessStats]
}

struct GPUStats: Codable, Sendable {
    var deviceUtilizationPercent: Int?
    var rendererUtilizationPercent: Int?
    var tilerUtilizationPercent: Int?
    var memoryInUseBytes: Int64?
    var allocatedSystemMemoryBytes: Int64?
}

struct LoadedModel: Codable, Sendable {
    var name: String
    var size: Int64
    var sizeVRAM: Int64
    var gpuPercent: Int
    var contextLength: Int?
    var quantization: String?
    var expiresAt: String?
}

struct StatsResponse: Codable, Sendable {
    var generatedAt: Date
    var uptimeSeconds: Double
    var ollamaReachable: Bool
    var ollamaVersion: String?
    var tokens: TokenSummary
    var recentRequests: [RequestSnapshot]
    var webTools: WebToolSummary
    var system: SystemStats
    var gpu: GPUStats
    var loadedModels: [LoadedModel]
}

struct VersionResponse: Codable, Sendable {
    var name: String
    var version: String
}
