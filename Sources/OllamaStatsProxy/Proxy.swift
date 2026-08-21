import AsyncHTTPClient
import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

struct Proxy: Sendable {
    static let trackedEndpoints = ["/api/generate", "/api/chat", "/v1/chat/completions", "/v1/completions"]
    static let hopHeaders = Set(["connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailers", "transfer-encoding", "upgrade", "host", "content-length"])

    let upstream: String
    let client: HTTPClient
    let store: StatsStore
    let metrics: MetricRecorder
    let activeRequests: ActiveRequestRegistry
    let orchestrator: ToolOrchestrator?

    func handle(_ incoming: Request, maxBodyBytes: Int) async throws -> Response {
        let body = try await incoming.body.collect(upTo: maxBodyBytes)
        let pathAndQuery = incoming.head.path ?? incoming.uri.description
        let path = String(pathAndQuery.prefix { $0 != "?" })
        let tracked = incoming.method == .post && Self.trackedEndpoints.contains(path)
        let metadata = extractMetadata(
            Data(body.readableBytesView), endpoint: path,
            benchmarkLabel: incoming.headers[HTTPField.Name("x-ollama-benchmark-label")!]
        )
        let requestID = tracked ? try await store.begin(metadata: metadata) : nil
        if let requestID { await activeRequests.begin(requestID) }

        if incoming.method == .post,
           let orchestrator,
           await orchestrator.shouldHandle(path: path, body: Data(body.readableBytesView)) {
            do {
                let orchestrationTask = Task {
                    try await orchestrator.handle(
                        path: path, incomingHeaders: incoming.headers,
                        body: Data(body.readableBytesView), requestID: requestID
                    )
                }
                if let requestID {
                    await activeRequests.install(requestID) { orchestrationTask.cancel() }
                }
                let result = try await orchestrationTask.value
                if let requestID {
                    var counter = StreamCounter(format: .json)
                    _ = counter.consume(Array(result.body))
                    for event in counter.finish() { metrics.record(.count(requestID, event)) }
                    metrics.record(.finish(requestID, nil))
                    await activeRequests.finish(requestID)
                }
                return Response(
                    status: HTTPResponse.Status(code: result.status),
                    headers: orchestrator.responseHeaders(for: result),
                    body: orchestrator.responseBody(for: result)
                )
            } catch {
                if let requestID {
                    let reason = await activeRequests.wasCancellationRequested(requestID)
                        ? ActiveRequestRegistry.cancellationReason : String(describing: error)
                    metrics.record(.finish(requestID, reason))
                    await activeRequests.finish(requestID)
                }
                let data = try JSONSerialization.data(withJSONObject: ["error": "server tool orchestration: \(error)"])
                var headers = HTTPFields(); headers[.contentType] = "application/json"
                return Response(status: .badGateway, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
            }
        }

        var upstreamRequest = HTTPClientRequest(url: upstream + pathAndQuery)
        switch incoming.method {
        case .get: upstreamRequest.method = .GET
        case .post: upstreamRequest.method = .POST
        case .put: upstreamRequest.method = .PUT
        case .patch: upstreamRequest.method = .PATCH
        case .delete: upstreamRequest.method = .DELETE
        case .head: upstreamRequest.method = .HEAD
        case .options: upstreamRequest.method = .OPTIONS
        default: upstreamRequest.method = .RAW(value: incoming.method.rawValue)
        }
        for field in incoming.headers where !Self.hopHeaders.contains(field.name.canonicalName) {
            upstreamRequest.headers.add(name: field.name.canonicalName, value: field.value)
        }
        if body.readableBytes > 0 { upstreamRequest.body = .bytes(body) }

        do {
            let upstreamTask = Task { try await client.execute(upstreamRequest, timeout: .hours(24)) }
            if let requestID { await activeRequests.install(requestID) { upstreamTask.cancel() } }
            let upstreamResponse = try await upstreamTask.value
            var headers = HTTPFields()
            for header in upstreamResponse.headers where !Self.hopHeaders.contains(header.name.lowercased()) {
                if let name = HTTPField.Name(header.name) { headers.append(HTTPField(name: name, value: header.value)) }
            }
            let contentType = upstreamResponse.headers.first(name: "content-type") ?? ""
            let format: StreamCounter.Format = contentType.contains("event-stream") ? .sse : contentType.contains("ndjson") ? .ndjson : .json
            let responseBody = ResponseBody { writer in
                let (chunks, continuation) = AsyncThrowingStream<ByteBuffer, Error>.makeStream()
                let upstreamBodyTask = Task {
                    do {
                        for try await chunk in upstreamResponse.body { continuation.yield(chunk) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                if let requestID { await activeRequests.install(requestID) { upstreamBodyTask.cancel() } }
                do {
                    var counter = StreamCounter(format: format)
                    for try await chunk in chunks {
                        let bytes = Array(chunk.readableBytesView)
                        try await writer.write(chunk)
                        if let requestID {
                            for event in counter.consume(bytes) { metrics.record(.count(requestID, event)) }
                        }
                    }
                    if let requestID {
                        for event in counter.finish() { metrics.record(.count(requestID, event)) }
                        metrics.record(.finish(requestID, nil))
                        await activeRequests.finish(requestID)
                    }
                    try await writer.finish(nil)
                } catch {
                    if let requestID {
                        let reason = await activeRequests.wasCancellationRequested(requestID)
                            ? ActiveRequestRegistry.cancellationReason : String(describing: error)
                        metrics.record(.finish(requestID, reason))
                        await activeRequests.finish(requestID)
                    }
                    throw error
                }
            }
            return Response(status: HTTPResponse.Status(code: Int(upstreamResponse.status.code)), headers: headers, body: responseBody)
        } catch {
            if let requestID {
                let reason = await activeRequests.wasCancellationRequested(requestID)
                    ? ActiveRequestRegistry.cancellationReason : String(describing: error)
                metrics.record(.finish(requestID, reason))
                await activeRequests.finish(requestID)
            }
            let data = try JSONSerialization.data(withJSONObject: ["error": "ollama proxy: \(error)"])
            var headers = HTTPFields(); headers[.contentType] = "application/json"
            return Response(status: .badGateway, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
        }
    }

    private func extractMetadata(_ body: Data, endpoint: String, benchmarkLabel: String?) -> RequestMetadata {
        let object = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let options = object["options"] as? [String: Any] ?? [:]
        let temperature = (object["temperature"] as? NSNumber)?.doubleValue
            ?? (options["temperature"] as? NSNumber)?.doubleValue
        let contextLength = (object["num_ctx"] as? NSNumber)?.intValue
            ?? (options["num_ctx"] as? NSNumber)?.intValue
        return RequestMetadata(
            model: object["model"] as? String ?? "?", endpoint: endpoint,
            temperature: temperature, contextLength: contextLength,
            thinkingEnabled: (object["think"] as? NSNumber)?.boolValue,
            benchmarkLabel: benchmarkLabel
        )
    }
}
