import Foundation

struct StreamCounter: Sendable {
    enum Format: Sendable { case ndjson, sse, json }

    let format: Format
    private(set) var buffer = Data()
    private(set) var finalBody = Data()

    mutating func consume(_ bytes: [UInt8]) -> [CountEvent] {
        let data = Data(bytes)
        if format == .json {
            finalBody.append(data)
            return []
        }
        buffer.append(data)
        var events: [CountEvent] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if let event = Self.parseLine(Data(line), format: format) { events.append(event) }
        }
        return events
    }

    mutating func finish() -> [CountEvent] {
        if format == .json { return Self.parseFinal(finalBody).map { [$0] } ?? [] }
        guard !buffer.isEmpty else { return [] }
        defer { buffer.removeAll() }
        return Self.parseLine(buffer, format: format).map { [$0] } ?? []
    }

    static func parseLine(_ data: Data, format: Format) -> CountEvent? {
        var payload = data
        if format == .sse {
            guard let string = String(data: data, encoding: .utf8), string.hasPrefix("data:") else { return nil }
            let value = string.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if value == "[DONE]" { return .done(FinalMetrics()) }
            payload = Data(value.utf8)
        }
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        if let usage = object["usage"] as? [String: Any] {
            return .done(FinalMetrics(outputTokens: usage["completion_tokens"] as? Int, promptTokens: usage["prompt_tokens"] as? Int))
        }
        if object["done"] as? Bool == true {
            return .done(FinalMetrics(object: object))
        }
        if format == .sse {
            let choices = object["choices"] as? [[String: Any]] ?? []
            for choice in choices {
                let delta = choice["delta"] as? [String: Any] ?? [:]
                if nonempty(delta["content"]) || nonempty(delta["reasoning_content"]) || nonempty(delta["reasoning"]) || nonempty(choice["text"]) { return .token }
            }
        } else {
            let message = object["message"] as? [String: Any] ?? [:]
            if nonempty(object["response"]) || nonempty(object["thinking"]) || nonempty(message["content"]) || nonempty(message["thinking"]) { return .token }
        }
        return nil
    }

    static func parseFinal(_ data: Data) -> CountEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let usage = object["usage"] as? [String: Any] {
            return .done(FinalMetrics(outputTokens: usage["completion_tokens"] as? Int, promptTokens: usage["prompt_tokens"] as? Int))
        }
        return .done(FinalMetrics(object: object))
    }

    private static func nonempty(_ value: Any?) -> Bool {
        guard let value else { return false }
        if let string = value as? String { return !string.isEmpty }
        return true
    }
}

enum CountEvent: Sendable, Equatable {
    case token
    case done(FinalMetrics)
}

struct FinalMetrics: Sendable, Equatable {
    var outputTokens: Int?
    var promptTokens: Int?
    var totalDurationNanoseconds: Int64?
    var loadDurationNanoseconds: Int64?
    var promptEvalDurationNanoseconds: Int64?
    var evalDurationNanoseconds: Int64?

    init(outputTokens: Int? = nil, promptTokens: Int? = nil, totalDurationNanoseconds: Int64? = nil, loadDurationNanoseconds: Int64? = nil, promptEvalDurationNanoseconds: Int64? = nil, evalDurationNanoseconds: Int64? = nil) {
        self.outputTokens = outputTokens
        self.promptTokens = promptTokens
        self.totalDurationNanoseconds = totalDurationNanoseconds
        self.loadDurationNanoseconds = loadDurationNanoseconds
        self.promptEvalDurationNanoseconds = promptEvalDurationNanoseconds
        self.evalDurationNanoseconds = evalDurationNanoseconds
    }

    init(object: [String: Any]) {
        func int64(_ key: String) -> Int64? { (object[key] as? NSNumber)?.int64Value }
        outputTokens = (object["eval_count"] as? NSNumber)?.intValue
        promptTokens = (object["prompt_eval_count"] as? NSNumber)?.intValue
        totalDurationNanoseconds = int64("total_duration")
        loadDurationNanoseconds = int64("load_duration")
        promptEvalDurationNanoseconds = int64("prompt_eval_duration")
        evalDurationNanoseconds = int64("eval_duration")
    }
}
