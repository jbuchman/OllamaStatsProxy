import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

enum APIResponses {
    static func json<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var headers = HTTPFields()
        headers[.contentType] = "application/json; charset=utf-8"
        headers[.cacheControl] = "no-store"
        return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: try encoder.encode(value))))
    }

    static func csv(_ records: [RequestRecord]) -> Response {
        let formatter = ISO8601DateFormatter()
        var lines = ["id,model,endpoint,started_at,ended_at,prompt_tokens,output_tokens,ttft_seconds,prompt_tokens_per_second,output_tokens_per_second,total_seconds,load_seconds,temperature,context_length,thinking,benchmark_label,resource_samples,average_cpu_percent,average_gpu_percent,average_memory_used_bytes,error"]
        for record in records {
            let fields: [String] = [
                record.id.map { String($0) } ?? "", record.model, record.endpoint,
                formatter.string(from: record.startedAt), record.endedAt.map(formatter.string) ?? "",
                String(record.promptTokens), String(record.outputTokens),
                record.timeToFirstTokenSeconds.map { String(format: "%.6f", $0) } ?? "",
                record.promptTokensPerSecond.map { String(format: "%.3f", $0) } ?? "",
                String(format: "%.3f", record.averageTokensPerSecond),
                record.totalDurationNanoseconds.map { String(format: "%.6f", Double($0) / 1_000_000_000) } ?? "",
                record.loadDurationNanoseconds.map { String(format: "%.6f", Double($0) / 1_000_000_000) } ?? "",
                record.temperature.map { String($0) } ?? "",
                record.contextLength.map { String($0) } ?? "",
                record.thinkingEnabled.map { String($0) } ?? "",
                record.benchmarkLabel ?? "", String(record.resourceSampleCount),
                record.averageCPUPercent.map { String(format: "%.3f", $0) } ?? "",
                record.averageGPUPercent.map { String(format: "%.3f", $0) } ?? "",
                record.averageMemoryUsedBytes.map(String.init) ?? "", record.error ?? ""
            ]
            lines.append(fields.map(csvEscape).joined(separator: ","))
        }
        var headers = HTTPFields()
        headers[.contentType] = "text/csv; charset=utf-8"
        headers[.contentDisposition] = "attachment; filename=ollama-benchmarks.csv"
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(string: lines.joined(separator: "\n") + "\n")))
    }

    private static func csvEscape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

struct PurgeResponse: Codable { var deleted: Int; var olderThan: Date }
