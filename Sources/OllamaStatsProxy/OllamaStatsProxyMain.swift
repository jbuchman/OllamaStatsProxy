import AsyncHTTPClient
import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import Darwin

@main
enum OllamaStatsProxyMain {
    static let version = "0.1.1"

    static func main() async throws {
        let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
        let configurationFile = try ConfigurationFile(
            path: options.configurationPath, defaults: options.appConfiguration,
            adminPasswordOverride: ProcessInfo.processInfo.environment["OLLAMA_ADMIN_PASSWORD"]
        )
        let adminAuthentication = AdminAuthentication(configuration: configurationFile)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: options.databasePath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let store = try StatsStore(path: options.databasePath)
        if let retentionDays = options.retentionDays {
            _ = try await store.purge(olderThan: Date().addingTimeInterval(-Double(retentionDays) * 86_400))
        }
        let client = HTTPClient(eventLoopGroupProvider: .singleton)
        let webClient = HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: .init(redirectConfiguration: .disallow)
        )
        let metrics = MetricRecorder(store: store)
        let activeRequests = ActiveRequestRegistry()
        let modelLifecycle = ModelLifecycleRegistry()
        let ollama = OllamaClient(httpClient: client, upstream: options.upstream)
        let webToolMonitor = WebToolMonitor(store: store)
        let webTools = WebTools(
            client: webClient, configuration: configurationFile, monitor: webToolMonitor
        )
        // URL fetching does not require a search provider. Keep server-owned tool
        // orchestration enabled so models can use fetch_url on its own; the
        // orchestrator only advertises search_web when a provider is configured.
        let orchestrator = ToolOrchestrator(
            upstream: options.upstream, client: client, webTools: webTools,
            configuration: configurationFile
        )
        let proxy = Proxy(
            upstream: options.upstream, client: client, store: store, metrics: metrics,
            activeRequests: activeRequests,
            orchestrator: orchestrator, configuration: configurationFile
        )
        let router = Router()

        router.get("/stats") { _, _ -> Response in
            let (tokens, requests, uptime) = try await store.snapshot(limit: options.historyLimit)
            async let status = ollama.status()
            async let machine = SystemCollector.collect()
            let (ollamaStatus, collected) = await (status, machine)
            let webToolStats = try await webToolMonitor.snapshot()
            var loadedModels = ollamaStatus.models
            for index in loadedModels.indices {
                loadedModels[index].keepAlive = await modelLifecycle.keepAlive(for: loadedModels[index].name)
            }
            let payload = StatsResponse(
                generatedAt: Date(), uptimeSeconds: uptime,
                ollamaReachable: ollamaStatus.reachable, ollamaVersion: ollamaStatus.version,
                tokens: tokens, recentRequests: requests, webTools: webToolStats,
                system: collected.0, gpu: collected.1, loadedModels: loadedModels,
                installedModels: ollamaStatus.installedModels
            )
            return try APIResponses.json(payload)
        }
        router.get("/version") { _, _ in
            try APIResponses.json(VersionResponse(name: "ollama-stats-proxy", version: Self.version))
        }
        router.get("/healthz") { _, _ in
            let status = await ollama.status()
            return try APIResponses.json(
                ["status": status.reachable ? "ok" : "degraded"],
                status: status.reachable ? .ok : .serviceUnavailable
            )
        }

        router.get("/monitor") { _, _ in Dashboard.response() }
        router.get("/tools/web/search") { request, _ in
            guard let query = request.uri.queryParameters.get("q"), !query.isEmpty else {
                return try APIResponses.json(["error": "missing q query parameter"])
            }
            let count = request.uri.queryParameters.get("count", as: Int.self) ?? 5
            do { return try APIResponses.json(try await webTools.search(query, count: count)) }
            catch { return try APIResponses.json(["error": String(describing: error)]) }
        }
        router.get("/tools/web/fetch") { request, _ in
            guard let url = request.uri.queryParameters.get("url"), !url.isEmpty else {
                return try APIResponses.json(["error": "missing url query parameter"])
            }
            do { return try APIResponses.json(try await webTools.fetch(url)) }
            catch WebToolError.disabled {
                return try APIResponses.json(["error": WebToolError.disabled.description], status: .forbidden)
            }
            catch let error as URLSafetyError {
                return try APIResponses.json(["error": error.description], status: .forbidden)
            }
            catch { return try APIResponses.json(["error": String(describing: error)]) }
        }
        router.get("/benchmarks") { _, _ in try APIResponses.json(await store.benchmarkSummaries()) }
        router.get("/requests") { request, _ in
            let page = request.uri.queryParameters.get("page", as: Int.self) ?? 1
            let pageSize = request.uri.queryParameters.get("pageSize", as: Int.self) ?? 10
            return try APIResponses.json(await store.requestPage(
                page: page, pageSize: pageSize,
                query: request.uri.queryParameters.get("q"),
                state: request.uri.queryParameters.get("state")
            ))
        }
        router.get("/requests/:id") { _, context in
            guard let id = context.parameters.get("id", as: Int64.self) else {
                return try APIResponses.json(["error": "invalid request id"], status: .badRequest)
            }
            guard let detail = try await store.requestDetail(id: id) else {
                return try APIResponses.json(["error": "request not found"], status: .notFound)
            }
            return try APIResponses.json(detail)
        }
        router.get("/web-tools/page") { request, _ in
            let page = request.uri.queryParameters.get("page", as: Int.self) ?? 1
            let pageSize = request.uri.queryParameters.get("pageSize", as: Int.self) ?? 10
            return try APIResponses.json(await store.webToolPage(
                page: page, pageSize: pageSize,
                query: request.uri.queryParameters.get("q"),
                state: request.uri.queryParameters.get("state")
            ))
        }
        router.get("/web-tools") { _, _ in try APIResponses.json(await store.allWebToolCalls()) }
        router.get("/admin/session") { request, _ in
            try APIResponses.json(AdminSessionResponse(
                passwordConfigured: await adminAuthentication.passwordConfigured(),
                authenticated: await adminAuthentication.isAuthenticated(headers: request.headers)
            ))
        }
        router.post("/admin/login") { request, _ in
            let body = try await request.body.collect(upTo: 64 * 1024)
            let login = try JSONDecoder().decode(AdminLoginRequest.self, from: Data(body.readableBytesView))
            guard login.username == nil || login.username == "admin",
                  let token = await adminAuthentication.login(password: login.password) else {
                return try APIResponses.json(["error": "invalid password"], status: .unauthorized)
            }
            var response = try APIResponses.json(["authenticated": true])
            response.headers[HTTPField.Name("set-cookie")!] = "\(AdminAuthentication.cookieName)=\(token); Path=/; Max-Age=43200; HttpOnly; SameSite=Strict"
            return response
        }
        router.post("/admin/logout") { request, _ in
            await adminAuthentication.logout(headers: request.headers)
            var response = try APIResponses.json(["authenticated": false])
            response.headers[HTTPField.Name("set-cookie")!] = "\(AdminAuthentication.cookieName)=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict"
            return response
        }
        router.get("/config") { request, _ in
            guard await adminAuthentication.isAuthenticated(headers: request.headers) else {
                return try APIResponses.json(["error": "authentication required"], status: .unauthorized)
            }
            return try APIResponses.json(await configurationFile.view())
        }
        router.put("/config") { request, _ in
            guard await adminAuthentication.isAuthenticated(headers: request.headers) else {
                return try APIResponses.json(["error": "authentication required"], status: .unauthorized)
            }
            let body = try await request.body.collect(upTo: 1024 * 1024)
            let update = try JSONDecoder().decode(ConfigurationUpdate.self, from: Data(body.readableBytesView))
            let changedPassword = !(update.adminPassword?.isEmpty ?? true)
            let view = try await configurationFile.update(update)
            if changedPassword { await adminAuthentication.invalidateSessions() }
            return try APIResponses.json(view)
        }
        router.get("/export.json") { _, _ in try APIResponses.json(await store.allRequests()) }
        router.get("/export.csv") { _, _ in APIResponses.csv(try await store.allRequests()) }
        router.delete("/history") { request, _ in
            guard await adminAuthentication.isAuthenticated(headers: request.headers) else {
                return try APIResponses.json(["error": "authentication required"], status: .unauthorized)
            }
            let days = request.uri.queryParameters.get("olderThanDays", as: Int.self) ?? 0
            let cutoff = days > 0 ? Date().addingTimeInterval(-Double(days) * 86_400) : Date()
            return try APIResponses.json(PurgeResponse(deleted: await store.purge(olderThan: cutoff), olderThan: cutoff))
        }
        router.post("/requests/:id/cancel") { request, context in
            guard await adminAuthentication.isAuthenticated(headers: request.headers) else {
                return try APIResponses.json(["error": "authentication required"], status: .unauthorized)
            }
            guard let requestID = context.parameters.get("id", as: Int64.self) else {
                return try APIResponses.json(["error": "invalid request id"], status: .badRequest)
            }
            switch await activeRequests.cancel(requestID) {
            case .cancelled:
                return try APIResponses.json(
                    CancelRequestResponse(requestID: requestID, status: "cancelling"),
                    status: .accepted
                )
            case .alreadyRequested:
                return try APIResponses.json(
                    CancelRequestResponse(requestID: requestID, status: "already cancelling"),
                    status: .conflict
                )
            case .notActive:
                return try APIResponses.json(["error": "request is not active"], status: .notFound)
            }
        }
        router.post("/models/lifecycle") { request, _ in
            guard await adminAuthentication.isAuthenticated(headers: request.headers) else {
                return try APIResponses.json(["error": "authentication required"], status: .unauthorized)
            }
            let body = try await request.body.collect(upTo: 64 * 1024)
            let action = try JSONDecoder().decode(ModelLifecycleRequest.self, from: Data(body.readableBytesView))
            guard !action.model.isEmpty, ["0", "5m", "-1"].contains(action.keepAlive) else {
                return try APIResponses.json(["error": "keepAlive must be 0, 5m, or -1"], status: .badRequest)
            }
            guard await modelLifecycle.begin(model: action.model) else {
                return try APIResponses.json(
                    ["error": "a lifecycle operation is already running for this model"],
                    status: .conflict
                )
            }
            do {
                try await ollama.setKeepAlive(model: action.model, keepAlive: action.keepAlive)
                await modelLifecycle.finish(model: action.model, appliedKeepAlive: action.keepAlive)
                return try APIResponses.json(ModelLifecycleResponse(
                    model: action.model, keepAlive: action.keepAlive, status: "applied"
                ))
            } catch {
                await modelLifecycle.finish(model: action.model)
                return try APIResponses.json(["error": "Ollama lifecycle request failed: \(error)"], status: .badGateway)
            }
        }

        // Serve dashboard assets bundled into the executable.
        router.get("/public/**") { request, _ -> Response in
            let requestedPath = request.uri.path.removingPercentEncoding ?? request.uri.path
            let name = String(requestedPath.dropFirst("/public/".count))
            if let response = Dashboard.resourceResponse(named: name) { return response }
            throw HTTPError(.notFound)
        }
        
        let methods: [HTTPRequest.Method] = [.get, .post, .put, .patch, .delete, .head, .options]
        for method in methods {
            router.on("**", method: method) { request, _ in
                try await proxy.handle(request, maxBodyBytes: options.maxBodyBytes)
            }
        }

        let app = Application(
            router: router,
            configuration: .init(address: .hostname(options.host, port: options.port))
        )

        print("ollama-stats-proxy listening on http://\(options.host):\(options.port)")
        print("proxying to \(options.upstream); stats at /stats; database at \(options.databasePath)")

        do {
            try await app.runService()
            try await client.shutdown()
            try await webClient.shutdown()
        } catch {
            try? await client.shutdown()
            try? await webClient.shutdown()
            throw error
        }
    }
}

private struct Options: Sendable {
    var host = "127.0.0.1"
    var port = 11_435
    var upstream = "http://127.0.0.1:11434"
    var databasePath = "./ollama-stats.sqlite"
    var historyLimit = 20
    var maxBodyBytes = 512 * 1024 * 1024
    var retentionDays: Int?
    var webSearchProvider: WebTools.SearchProvider? = ProcessInfo.processInfo.environment["OLLAMA_WEB_SEARCH_PROVIDER"]
        .flatMap { WebTools.SearchProvider(rawValue: $0.lowercased()) }
    var webSearchAPIKey: String? = ProcessInfo.processInfo.environment["OLLAMA_WEB_SEARCH_API_KEY"]
    var webSearchURL: String? = ProcessInfo.processInfo.environment["OLLAMA_WEB_SEARCH_URL"]
    var webFetchMaxBytes = 8 * 1024 * 1024
    var webFetchMaxCharacters = 50_000
    var serverToolsEnabled = true
    var serverToolRounds = 4
    var configurationPath = "./ollama-stats-proxy.json"

    var appConfiguration: AppConfiguration {
        AppConfiguration(
            webSearchProvider: webSearchProvider, webSearchAPIKey: webSearchAPIKey,
            webSearchURL: webSearchURL, webFetchMaxBytes: webFetchMaxBytes,
            webFetchMaxCharacters: webFetchMaxCharacters,
            webFetchEnabled: true,
            webFetchAllowPrivateNetworks: false,
            serverToolsEnabled: serverToolsEnabled, serverToolRounds: serverToolRounds,
            adminPasswordHash: nil, langflowURL: "http://127.0.0.1:7860",
            langflowAPIKey: nil, virtualModels: []
        )
    }

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            func value() throws -> String {
                guard index + 1 < arguments.count else { throw OptionError.missingValue(arguments[index]) }
                index += 1
                return arguments[index]
            }
            switch arguments[index] {
            case "--host": host = try value()
            case "--port": port = Int(try value()) ?? port
            case "--upstream": upstream = try value().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            case "--database": databasePath = try value()
            case "--history-limit": historyLimit = Int(try value()) ?? historyLimit
            case "--max-body-mb": maxBodyBytes = (Int(try value()) ?? 512) * 1024 * 1024
            case "--retention-days": retentionDays = Int(try value())
            case "--web-search-provider": webSearchProvider = WebTools.SearchProvider(rawValue: try value().lowercased())
            case "--web-search-api-key": webSearchAPIKey = try value()
            case "--web-search-url": webSearchURL = try value()
            case "--web-fetch-max-mb": webFetchMaxBytes = (Int(try value()) ?? 8) * 1024 * 1024
            case "--web-fetch-max-chars": webFetchMaxCharacters = Int(try value()) ?? webFetchMaxCharacters
            case "--server-tool-rounds": serverToolRounds = max(1, Int(try value()) ?? serverToolRounds)
            case "--no-server-tools": serverToolsEnabled = false
            case "--config": configurationPath = try value()
            case "--help", "-h":
                print("Usage: ollama-stats-proxy [--host 127.0.0.1] [--port 11435] [--upstream http://127.0.0.1:11434] [--database ./ollama-stats.sqlite] [--config ./ollama-stats-proxy.json] [--retention-days N] [--web-search-provider brave|tavily|searxng] [--web-search-api-key KEY] [--web-search-url URL] [--server-tool-rounds N] [--no-server-tools]")
                Darwin.exit(0)
            default: throw OptionError.unknown(arguments[index])
            }
            index += 1
        }
    }
}

private enum OptionError: Error, CustomStringConvertible {
    case missingValue(String), unknown(String)
    var description: String {
        switch self {
        case .missingValue(let option): "Missing value for \(option)"
        case .unknown(let option): "Unknown option: \(option)"
        }
    }
}
