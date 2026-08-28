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
    let configuration: ConfigurationFile

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

        // Ollama clients discover available models through /api/tags. Merge enabled
        // Langflow virtual models into the real Ollama model list so clients can
        // select them exactly like locally installed models.
        if incoming.method == .get, path == "/api/tags" {
            return try await mergedTagsResponse()
        }

        // OpenAI-compatible clients (including 3sparks Chat) discover models through
        // /v1/models instead of Ollama's native /api/tags. Expose the same virtual
        // models in that dialect as well.
        if incoming.method == .get, path == "/v1/models" || path == "/v1/models/" {
            return try await mergedOpenAIModelsResponse()
        }

        if incoming.method == .get, path.hasPrefix("/v1/models/") {
            let encodedName = String(path.dropFirst("/v1/models/".count))
            let modelName = encodedName.removingPercentEncoding ?? encodedName
            let langflow = LangflowClient(client: client, configuration: configuration)
            if let virtual = await langflow.virtualModel(named: modelName) {
                return try Self.virtualOpenAIModelResponse(virtual)
            }
        }

        // Some clients immediately probe /api/show after model selection. A virtual
        // model has no Ollama manifest, so synthesize the minimal compatible metadata
        // locally instead of forwarding the request to Ollama (which would 404).
        if incoming.method == .post, path == "/api/show",
           let object = try? JSONSerialization.jsonObject(with: Data(body.readableBytesView)) as? [String: Any],
           let modelName = object["model"] as? String {
            let langflow = LangflowClient(client: client, configuration: configuration)
            if let virtual = await langflow.virtualModel(named: modelName) {
                return try Self.virtualShowResponse(virtual)
            }
        }

        if incoming.method == .post, path == "/api/chat",
           let modelName = metadata.model == "?" ? nil : metadata.model {
            let langflow = LangflowClient(client: client, configuration: configuration)
            if let virtual = await langflow.virtualModel(named: modelName) {
                do {
                    let task = Task { try await langflow.chat(model: virtual, ollamaBody: Data(body.readableBytesView)) }
                    if let requestID { await activeRequests.install(requestID) { task.cancel() } }
                    let data = try await task.value
                    if let requestID {
                        var counter = StreamCounter(format: .ndjson)
                        for event in counter.consume(Array(data)) { metrics.record(.count(requestID, event)) }
                        for event in counter.finish() { metrics.record(.count(requestID, event)) }
                        metrics.record(.finish(requestID, nil)); await activeRequests.finish(requestID)
                    }
                    var headers = HTTPFields()
                    headers[.contentType] = ((try? JSONSerialization.jsonObject(with: Data(body.readableBytesView)) as? [String: Any])?["stream"] as? Bool ?? true) ? "application/x-ndjson" : "application/json"
                    return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
                } catch {
                    if let requestID { metrics.record(.finish(requestID, String(describing: error))); await activeRequests.finish(requestID) }
                    let data = try JSONSerialization.data(withJSONObject: ["error": "langflow: \(error)"])
                    var headers = HTTPFields(); headers[.contentType] = "application/json"
                    return Response(status: .badGateway, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
                }
            }
        }

        if incoming.method == .post, path == "/v1/chat/completions",
           let modelName = metadata.model == "?" ? nil : metadata.model {
            let langflow = LangflowClient(client: client, configuration: configuration)
            if let virtual = await langflow.virtualModel(named: modelName) {
                do {
                    let task = Task { try await langflow.openAIChat(model: virtual, body: Data(body.readableBytesView)) }
                    if let requestID { await activeRequests.install(requestID) { task.cancel() } }
                    let data = try await task.value
                    if let requestID {
                        metrics.record(.finish(requestID, nil))
                        await activeRequests.finish(requestID)
                    }
                    let requestObject = try? JSONSerialization.jsonObject(with: Data(body.readableBytesView)) as? [String: Any]
                    let streaming = requestObject?["stream"] as? Bool ?? false
                    var headers = HTTPFields()
                    headers[.contentType] = streaming ? "text/event-stream" : "application/json"
                    if streaming { headers[HTTPField.Name("cache-control")!] = "no-cache" }
                    return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
                } catch {
                    if let requestID {
                        metrics.record(.finish(requestID, String(describing: error)))
                        await activeRequests.finish(requestID)
                    }
                    let data = try JSONSerialization.data(withJSONObject: [
                        "error": ["message": "langflow: \(error)", "type": "api_error"]
                    ])
                    var headers = HTTPFields(); headers[.contentType] = "application/json"
                    return Response(status: .badGateway, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
                }
            }
        }

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

    private func mergedTagsResponse() async throws -> Response {
        var request = HTTPClientRequest(url: upstream + "/api/tags")
        request.method = .GET
        let upstreamResponse = try await client.execute(request, timeout: .seconds(30))
        let collected = try await upstreamResponse.body.collect(upTo: 64 * 1024 * 1024)
        let data = Data(collected.readableBytesView)

        guard (200..<300).contains(Int(upstreamResponse.status.code)) else {
            var headers = HTTPFields()
            headers[.contentType] = upstreamResponse.headers.first(name: "content-type") ?? "application/json"
            return Response(
                status: HTTPResponse.Status(code: Int(upstreamResponse.status.code)),
                headers: headers,
                body: .init(byteBuffer: ByteBuffer(bytes: data))
            )
        }

        var root = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        var models = root["models"] as? [[String: Any]] ?? []
        var names = Set(models.compactMap { item in
            (item["name"] as? String ?? item["model"] as? String)?.lowercased()
        })

        let config = await configuration.value()
        for virtual in config.virtualModels ?? [] where virtual.enabled {
            let key = virtual.name.lowercased()
            guard names.insert(key).inserted else { continue }
            models.append(Self.virtualTag(virtual))
        }
        root["models"] = models

        let merged = try JSONSerialization.data(withJSONObject: root)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: merged)))
    }

    private func mergedOpenAIModelsResponse() async throws -> Response {
        var request = HTTPClientRequest(url: upstream + "/v1/models")
        request.method = .GET
        let upstreamResponse = try await client.execute(request, timeout: .seconds(30))
        let collected = try await upstreamResponse.body.collect(upTo: 64 * 1024 * 1024)
        let data = Data(collected.readableBytesView)

        guard (200..<300).contains(Int(upstreamResponse.status.code)) else {
            var headers = HTTPFields()
            headers[.contentType] = upstreamResponse.headers.first(name: "content-type") ?? "application/json"
            return Response(
                status: HTTPResponse.Status(code: Int(upstreamResponse.status.code)),
                headers: headers,
                body: .init(byteBuffer: ByteBuffer(bytes: data))
            )
        }

        var root = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? ["object": "list"]
        var models = root["data"] as? [[String: Any]] ?? []
        var names = Set(models.compactMap { ($0["id"] as? String)?.lowercased() })
        let config = await configuration.value()
        for virtual in config.virtualModels ?? [] where virtual.enabled {
            let key = virtual.name.lowercased()
            guard names.insert(key).inserted else { continue }
            models.append(Self.virtualOpenAIModel(virtual))
        }
        root["object"] = "list"
        root["data"] = models

        let merged = try JSONSerialization.data(withJSONObject: root)
        var headers = HTTPFields(); headers[.contentType] = "application/json"
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: merged)))
    }

    private static func virtualOpenAIModel(_ model: VirtualModel) -> [String: Any] {
        [
            "id": model.name,
            "object": "model",
            "created": 0,
            "owned_by": "langflow"
        ]
    }

    private static func virtualOpenAIModelResponse(_ model: VirtualModel) throws -> Response {
        let data = try JSONSerialization.data(withJSONObject: virtualOpenAIModel(model))
        var headers = HTTPFields(); headers[.contentType] = "application/json"
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    private static func virtualTag(_ model: VirtualModel) -> [String: Any] {
        [
            "name": model.name,
            "model": model.name,
            "modified_at": "1970-01-01T00:00:00Z",
            "size": 0,
            "digest": virtualDigest(flowID: model.flowID),
            "details": [
                "format": "langflow",
                "family": "langflow",
                "families": ["langflow"],
                "parameter_size": "virtual",
                "quantization_level": ""
            ]
        ]
    }

    private static func virtualShowResponse(_ model: VirtualModel) throws -> Response {
        let object: [String: Any] = [
            "parameters": "",
            "template": "",
            "license": "",
            "capabilities": ["completion"],
            "modified_at": "1970-01-01T00:00:00Z",
            "details": [
                "parent_model": "",
                "format": "langflow",
                "family": "langflow",
                "families": ["langflow"],
                "parameter_size": "virtual",
                "quantization_level": ""
            ],
            "model_info": [
                "ollama_stats_proxy.backend": "langflow",
                "ollama_stats_proxy.flow_id": model.flowID
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    // This is an identifier, not a cryptographic integrity check. Keep it stable and
    // digest-shaped because a few Ollama clients assume the field is 64 hex chars.
    private static func virtualDigest(flowID: String) -> String {
        let bytes = Array(flowID.utf8)
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        let chunk = String(format: "%016llx", hash)
        return String(repeating: chunk, count: 4)
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
