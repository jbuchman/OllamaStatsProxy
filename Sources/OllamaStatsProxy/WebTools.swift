import AsyncHTTPClient
import Foundation
import NIOCore

struct WebSearchResult: Codable, Sendable {
    var title: String
    var url: String
    var snippet: String?
}

struct WebSearchResponse: Codable, Sendable {
    var query: String
    var provider: String
    var results: [WebSearchResult]
}

struct WebFetchResponse: Codable, Sendable {
    var url: String
    var title: String?
    var text: String
    var truncated: Bool
}

enum WebToolError: Error, CustomStringConvertible {
    case notConfigured
    case disabled
    case badURL
    case badResponse(Int)
    case malformedResponse

    var description: String {
        switch self {
        case .notConfigured: "Web search is not configured. Set --web-search-provider and the provider credentials/URL."
        case .disabled: "Web fetch is disabled in the proxy configuration."
        case .badURL: "Invalid URL"
        case .badResponse(let status): "Web request failed with HTTP \(status)"
        case .malformedResponse: "Search provider returned an unexpected response"
        }
    }
}

struct WebTools: Sendable {
    enum SearchProvider: String, Codable, Sendable {
        case brave, tavily, searxng
    }

    let client: HTTPClient
    let configuration: ConfigurationFile
    let monitor: WebToolMonitor

    func search(_ query: String, count: Int = 5, source: String = "endpoint", requestID: Int64? = nil) async throws -> WebSearchResponse {
        let startedAt = Date()
        do {
            let configuration = await configuration.value()
            let provider = configuration.webSearchProvider
            guard let provider else { throw WebToolError.notConfigured }
            let result: WebSearchResponse
            switch provider {
            case .brave: result = try await searchBrave(query, count: count, configuration: configuration)
            case .tavily: result = try await searchTavily(query, count: count, configuration: configuration)
            case .searxng: result = try await searchSearXNG(query, count: count, configuration: configuration)
            }
            await monitor.record(requestID: requestID, startedAt: startedAt, tool: "search", source: source, resource: query, resultCount: result.results.count)
            return result
        } catch {
            await monitor.record(requestID: requestID, startedAt: startedAt, tool: "search", source: source, resource: query, error: error)
            throw error
        }
    }

    func fetch(_ rawURL: String, source: String = "endpoint", requestID: Int64? = nil) async throws -> WebFetchResponse {
        let startedAt = Date()
        do {
            let configuration = await configuration.value()
            guard configuration.webFetchEnabled != false else { throw WebToolError.disabled }
            guard var url = URL(string: rawURL) else { throw WebToolError.badURL }
            var finalResponse: HTTPClientResponse?
            for redirectCount in 0...5 {
                try await URLSafety.validate(
                    url, allowPrivateNetworks: configuration.webFetchAllowPrivateNetworks == true
                )
                var request = HTTPClientRequest(url: url.absoluteString)
                request.method = .GET
                request.headers.add(name: "user-agent", value: "OllamaStatsProxy/1.0")
                request.headers.add(name: "accept", value: "text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5")
                let response = try await client.execute(request, timeout: .seconds(20))
                let status = Int(response.status.code)
                if (300..<400).contains(status), let location = response.headers.first(name: "location") {
                    guard redirectCount < 5,
                          let redirected = URL(string: location, relativeTo: url)?.absoluteURL
                    else { throw URLSafetyError.tooManyRedirects }
                    url = redirected
                    continue
                }
                guard (200..<300).contains(status) else { throw WebToolError.badResponse(status) }
                finalResponse = response
                break
            }
            guard let response = finalResponse else { throw URLSafetyError.tooManyRedirects }
            let body = try await response.body.collect(upTo: configuration.webFetchMaxBytes)
            let data = Data(body.readableBytesView)
            let contentType = response.headers.first(name: "content-type")?.lowercased() ?? ""
            let bodySource = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            let title = contentType.contains("html") ? Self.extractTitle(bodySource) : nil
            let cleaned = contentType.contains("html") ? Self.markdownText(bodySource, baseURL: url) : bodySource
            let result = WebFetchResponse(
                url: url.absoluteString, title: title,
                text: String(cleaned.prefix(configuration.webFetchMaxCharacters)),
                truncated: cleaned.count > configuration.webFetchMaxCharacters
            )
            await monitor.record(requestID: requestID, startedAt: startedAt, tool: "fetch", source: source, resource: rawURL, responseBytes: data.count)
            return result
        } catch {
            await monitor.record(requestID: requestID, startedAt: startedAt, tool: "fetch", source: source, resource: rawURL, error: error)
            throw error
        }
    }

    private func searchBrave(_ query: String, count: Int, configuration: AppConfiguration) async throws -> WebSearchResponse {
        guard let apiKey = configuration.webSearchAPIKey, !apiKey.isEmpty else { throw WebToolError.notConfigured }
        var components = URLComponents(string: configuration.webSearchURL ?? "https://api.search.brave.com/res/v1/web/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "count", value: String(min(max(count, 1), 20)))]
        var request = HTTPClientRequest(url: components.url!.absoluteString)
        request.headers.add(name: "accept", value: "application/json")
        request.headers.add(name: "x-subscription-token", value: apiKey)
        let object = try await json(request)
        guard let web = object["web"] as? [String: Any], let items = web["results"] as? [[String: Any]] else { throw WebToolError.malformedResponse }
        return WebSearchResponse(query: query, provider: SearchProvider.brave.rawValue, results: items.prefix(count).compactMap {
            guard let title = $0["title"] as? String, let url = $0["url"] as? String else { return nil }
            return WebSearchResult(title: title, url: url, snippet: $0["description"] as? String)
        })
    }

    private func searchTavily(_ query: String, count: Int, configuration: AppConfiguration) async throws -> WebSearchResponse {
        guard let apiKey = configuration.webSearchAPIKey, !apiKey.isEmpty else { throw WebToolError.notConfigured }
        var request = HTTPClientRequest(url: configuration.webSearchURL ?? "https://api.tavily.com/search")
        request.method = .POST
        request.headers.add(name: "content-type", value: "application/json")
        let payload: [String: Any] = ["api_key": apiKey, "query": query, "max_results": min(max(count, 1), 20), "include_answer": false, "include_raw_content": false]
        request.body = .bytes(ByteBuffer(bytes: try JSONSerialization.data(withJSONObject: payload)))
        let object = try await json(request)
        guard let items = object["results"] as? [[String: Any]] else { throw WebToolError.malformedResponse }
        return WebSearchResponse(query: query, provider: SearchProvider.tavily.rawValue, results: items.prefix(count).compactMap {
            guard let title = $0["title"] as? String, let url = $0["url"] as? String else { return nil }
            return WebSearchResult(title: title, url: url, snippet: $0["content"] as? String)
        })
    }

    private func searchSearXNG(_ query: String, count: Int, configuration: AppConfiguration) async throws -> WebSearchResponse {
        guard let base = configuration.webSearchURL, var components = URLComponents(string: base) else { throw WebToolError.notConfigured }
        var items = components.queryItems ?? []
        items += [URLQueryItem(name: "q", value: query), URLQueryItem(name: "format", value: "json")]
        components.queryItems = items
        guard let url = components.url else { throw WebToolError.badURL }
        let object = try await json(HTTPClientRequest(url: url.absoluteString))
        guard let results = object["results"] as? [[String: Any]] else { throw WebToolError.malformedResponse }
        return WebSearchResponse(query: query, provider: SearchProvider.searxng.rawValue, results: results.prefix(count).compactMap {
            guard let title = $0["title"] as? String, let url = $0["url"] as? String else { return nil }
            return WebSearchResult(title: title, url: url, snippet: $0["content"] as? String)
        })
    }

    private func json(_ request: HTTPClientRequest) async throws -> [String: Any] {
        let response = try await client.execute(request, timeout: .seconds(20))
        guard (200..<300).contains(Int(response.status.code)) else { throw WebToolError.badResponse(Int(response.status.code)) }
        let body = try await response.body.collect(upTo: 8 * 1024 * 1024)
        guard let object = try JSONSerialization.jsonObject(with: Data(body.readableBytesView)) as? [String: Any] else { throw WebToolError.malformedResponse }
        return object
    }

    private static func extractTitle(_ html: String) -> String? {
        guard let range = html.range(of: #"<title[^>]*>(.*?)</title>"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return plainText(String(html[range]))
            .replacingOccurrences(of: "title", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func markdownText(_ html: String, baseURL: URL) -> String {
        var text = html
        for pattern in [#"(?is)<script\b[^>]*>.*?</script>"#, #"(?is)<style\b[^>]*>.*?</style>"#, #"(?is)<noscript\b[^>]*>.*?</noscript>"#, #"(?is)<!--.*?-->"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }

        text = replacingMatches(in: text, pattern: #"(?is)<pre\b[^>]*>(.*?)</pre>"#) { match in
            let code = plainText(match[1])
                .replacingOccurrences(of: "<", with: "\u{E000}")
                .replacingOccurrences(of: ">", with: "\u{E001}")
            return "\n```\n\(code)\n```\n"
        }
        text = replacingMatches(in: text, pattern: #"(?is)<a\b[^>]*\bhref\s*=\s*[\"']([^\"']+)[\"'][^>]*>(.*?)</a>"#) { match in
            let label = plainText(match[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let resolved = URL(string: match[1], relativeTo: baseURL)?.absoluteURL,
                  let scheme = resolved.scheme?.lowercased(), ["http", "https"].contains(scheme)
            else { return label }
            let destination = resolved.absoluteString
                .replacingOccurrences(of: "(", with: "%28")
                .replacingOccurrences(of: ")", with: "%29")
            let safeLabel = (label.isEmpty ? resolved.absoluteString : label)
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
            return "[\(safeLabel)](\(destination))"
        }
        text = replacingMatches(in: text, pattern: #"(?is)<h([1-6])\b[^>]*>(.*?)</h[1-6]>"#) { match in
            let level = Int(match[1]) ?? 1
            return "\n\(String(repeating: "#", count: level)) \(plainText(match[2]))\n"
        }
        text = replacingMatches(in: text, pattern: #"(?is)<li\b[^>]*>(.*?)</li>"#) { match in
            "\n- \(plainText(match[1]))"
        }
        text = replacingMatches(in: text, pattern: #"(?is)<blockquote\b[^>]*>(.*?)</blockquote>"#) { match in
            "\n> \(plainText(match[1]))\n"
        }
        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>|</p\s*>|</div\s*>|</section\s*>|</article\s*>|</ul\s*>|</ol\s*>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: "\u{E000}", with: "<")
            .replacingOccurrences(of: "\u{E001}", with: ">")
        text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n\s*\n\s*\n+"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func plainText(_ html: String) -> String {
        decodeEntities(html.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        for (entity, value) in entities { result = result.replacingOccurrences(of: entity, with: value) }
        return result
    }

    private static func replacingMatches(
        in input: String, pattern: String, transform: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        var output = input
        let matches = regex.matches(in: input, range: NSRange(input.startIndex..., in: input))
        for match in matches.reversed() {
            guard let wholeRange = Range(match.range(at: 0), in: input) else { continue }
            let captures = (0..<match.numberOfRanges).map { index -> String in
                guard match.range(at: index).location != NSNotFound,
                      let range = Range(match.range(at: index), in: input) else { return "" }
                return String(input[range])
            }
            output.replaceSubrange(wholeRange, with: transform(captures))
        }
        return output
    }
}
