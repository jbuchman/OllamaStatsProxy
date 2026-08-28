import AppKit
import AsyncHTTPClient
import CoreText
import Foundation
import HTTPTypes
import ImageIO
import NIOCore

struct MagazineDigestRequest: Codable, Sendable {
    var query: String
    var model: String
    var title: String?
    var storyCount: Int?
}

struct MagazineDigestIssue: Codable, Sendable {
    var title: String
    var subtitle: String
    var editorNote: String
    var stories: [MagazineDigestStory]
}

struct MagazineDigestStory: Codable, Sendable {
    var headline: String
    var deck: String
    var body: String
    var keyPoints: [String]
    var sourceNumbers: [Int]
}

struct MagazineSource: Sendable {
    var number: Int
    var title: String
    var url: String
    var text: String
    var imageURL: String?
    var imageData: Data?
}

enum MagazineDigestError: Error, CustomStringConvertible {
    case invalidRequest(String)
    case noResults
    case noReadableSources
    case ollama(Int, String)
    case malformedEditorialOutput
    case renderingFailed

    var description: String {
        switch self {
        case .invalidRequest(let message): message
        case .noResults: "The search returned no results."
        case .noReadableSources: "None of the search results could be read."
        case .ollama(let status, let message): "Ollama returned HTTP \(status): \(message)"
        case .malformedEditorialOutput: "Ollama did not return a valid structured magazine issue."
        case .renderingFailed: "The PDF renderer could not create the issue."
        }
    }
}

struct MagazineDigestService: Sendable {
    let client: HTTPClient
    let upstream: String
    let webTools: WebTools

    func create(_ request: MagazineDigestRequest) async throws -> Data {
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw MagazineDigestError.invalidRequest("Query is required.") }
        guard !model.isEmpty else { throw MagazineDigestError.invalidRequest("Model is required.") }
        let storyCount = min(max(request.storyCount ?? 5, 2), 8)
        let searchDate = DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .none)
        let discoveryQuery = "\(query) latest reporting analysis \(searchDate)"
        let search = try await webTools.search(discoveryQuery, count: min(storyCount * 2, 16), source: "magazine")
        guard !search.results.isEmpty else { throw MagazineDigestError.noResults }

        var candidateURLs: [String] = []
        for result in search.results {
            if Self.looksLikeArticleURL(result.url) {
                candidateURLs.append(result.url)
                continue
            }
            guard let landing = try? await webTools.fetchPage(result.url, source: "magazine") else { continue }
            candidateURLs.append(contentsOf: Self.articleLinks(in: landing.response.text).prefix(4))
        }
        var seen = Set<String>()
        candidateURLs = candidateURLs.filter { seen.insert($0).inserted }

        var sources: [MagazineSource] = []
        for candidateURL in candidateURLs {
            guard let page = try? await webTools.fetchPage(candidateURL, source: "magazine") else { continue }
            let articleText = Self.cleanArticleText(page.response.text)
            guard articleText.count >= 900 else { continue }
            let number = sources.count + 1
            let imageData: Data? = if let imageURL = page.imageURL {
                try? await webTools.downloadImage(imageURL, source: "magazine")
            } else { nil }
            sources.append(MagazineSource(
                number: number,
                title: page.response.title?.nilIfEmpty ?? "Reported feature",
                url: page.response.url,
                text: String(articleText.prefix(12_000)),
                imageURL: page.imageURL,
                imageData: imageData
            ))
            if sources.count >= min(storyCount * 2, 12) { break }
        }
        guard !sources.isEmpty else { throw MagazineDigestError.noReadableSources }

        var issue = try await editIssue(
            query: query, model: model, requestedTitle: request.title,
            storyCount: storyCount, sources: sources
        )
        issue = try await deepenIssue(issue, query: query, model: model, storyCount: storyCount, sources: sources)
        issue.stories = Array(issue.stories.prefix(storyCount))
        let valid = Set(sources.map(\.number))
        for index in issue.stories.indices {
            issue.stories[index].sourceNumbers = issue.stories[index].sourceNumbers.filter(valid.contains)
        }
        return try MagazinePDFRenderer().render(issue: issue, sources: sources, date: Date())
    }

    static func looksLikeArticleURL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL) else { return false }
        let path = url.path.lowercased()
        let blocked = ["/tag/", "/tags/", "/category/", "/section/", "/topics/", "/about", "/events", "/login"]
        if path == "/" || blocked.contains(where: path.contains) { return false }
        if path.range(of: #"/20\d{2}/(?:0?[1-9]|1[0-2])/(?:0?[1-9]|[12]\d|3[01])/"#, options: .regularExpression) != nil {
            return true
        }
        let components = path.split(separator: "/")
        return components.count >= 2 && (components.last?.count ?? 0) >= 24
    }

    static func articleLinks(in markdown: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\[([^\]]{18,})\]\((https?://[^)]+)\)"#) else { return [] }
        let range = NSRange(markdown.startIndex..., in: markdown)
        return regex.matches(in: markdown, range: range).compactMap { match in
            guard let urlRange = Range(match.range(at: 2), in: markdown) else { return nil }
            let url = String(markdown[urlRange])
            return looksLikeArticleURL(url) ? url : nil
        }
    }

    static func cleanArticleText(_ markdown: String) -> String {
        var text = markdown.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression
        )
        text = text.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        let lines = text.components(separatedBy: .newlines).compactMap { raw -> String? in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  !line.hasPrefix("- "), !line.hasPrefix("#"), !line.hasPrefix("Skip "),
                  !line.hasPrefix("Sign in"), !line.hasPrefix("Subscribe"),
                  line.count >= 35 else { return nil }
            return line
        }
        return lines.joined(separator: "\n\n")
    }

    private func editIssue(
        query: String, model: String, requestedTitle: String?, storyCount: Int,
        sources: [MagazineSource]
    ) async throws -> MagazineDigestIssue {
        // Keep the editorial request within the practical context window of smaller
        // local models. An oversized packet often causes them to echo a source record
        // instead of following the output schema.
        var remainingSourceCharacters = 36_000
        var sourceSections: [String] = []
        for source in sources.prefix(8) where remainingSourceCharacters > 0 {
            let excerptLength = min(4_500, remainingSourceCharacters)
            let excerpt = String(source.text.prefix(excerptLength))
            sourceSections.append(
                "SOURCE [\(source.number)]\nTITLE: \(source.title)\nURL: \(source.url)\n\(excerpt)"
            )
            remainingSourceCharacters -= excerpt.count
        }
        let sourceText = sourceSections.joined(separator: "\n\n---\n\n")
        let titleDirection = requestedTitle?.nilIfEmpty.map { "Use this publication title: \($0)." } ?? "Create a concise publication title."
        let prompt = """
        Create a polished morning-news magazine about: \(query)
        \(titleDirection)
        Produce exactly \(storyCount) stories when the source material supports it. Synthesize and compare sources; do not copy long passages. Every factual story must cite source numbers from the supplied packet. Body text should be 350-650 words per feature, written in clear magazine prose. Key points must contain 2-4 short items. Do not invent facts or source numbers. Return JSON only.

        SOURCE PACKET
        \(sourceText)
        """
        let schema: [String: Any] = [
            "type": "object",
            "required": ["title", "subtitle", "editorNote", "stories"],
            "properties": [
                "title": ["type": "string"],
                "subtitle": ["type": "string"],
                "editorNote": ["type": "string"],
                "stories": [
                    "type": "array", "minItems": 1, "maxItems": storyCount,
                    "items": [
                        "type": "object",
                        "required": ["headline", "deck", "body", "keyPoints", "sourceNumbers"],
                        "properties": [
                            "headline": ["type": "string"], "deck": ["type": "string"],
                            "body": ["type": "string"],
                            "keyPoints": ["type": "array", "items": ["type": "string"]],
                            "sourceNumbers": ["type": "array", "items": ["type": "integer"]]
                        ]
                    ]
                ]
            ]
        ]
        let messages: [[String: String]] = [
            ["role": "system", "content": "You are a careful newspaper editor. Output only schema-valid JSON and ground every claim in the supplied sources."],
            ["role": "user", "content": prompt]
        ]
        let payload: [String: Any] = [
            "model": model, "stream": false, "format": schema,
            "options": ["temperature": 0.3],
            "messages": messages
        ]
        let content = try await ollamaContent(payload)
        if let issue = Self.decodeIssue(from: content) { return issue }

        // Smaller local models sometimes wrap JSON in prose or miss a required key even
        // when a schema is supplied. Give the model one cheap, source-free repair pass.
        let repairPayload: [String: Any] = [
            "model": model, "stream": false, "format": schema,
            "options": ["temperature": 0],
            "messages": [
                ["role": "system", "content": "Return one JSON magazine object with exactly these top-level keys: title, subtitle, editorNote, stories. Every story must contain headline, deck, body, keyPoints, and sourceNumbers. Do not return source records, URL fields, Markdown, or commentary."],
                ["role": "user", "content": "Rewrite this failed draft into the required magazine object. JSON only:\n\n\(String(content.prefix(24_000)))"]
            ]
        ]
        let repaired = try await ollamaContent(repairPayload)
        if let issue = Self.decodeIssue(from: repaired) { return issue }

        // A digest should still be useful with models that do not support reliable
        // structured output. Build a source-led edition instead of failing the request.
        return Self.sourceLedIssue(
            query: query, requestedTitle: requestedTitle,
            storyCount: storyCount, sources: sources
        )
    }

    private func deepenIssue(
        _ draft: MagazineDigestIssue, query: String, model: String,
        storyCount: Int, sources: [MagazineSource]
    ) async throws -> MagazineDigestIssue {
        var issue = draft
        var stories: [MagazineDigestStory] = []
        let validNumbers = Set(sources.map(\.number))
        let desiredCount = min(storyCount, sources.count)
        for index in 0..<desiredCount {
            let seed = index < draft.stories.count ? draft.stories[index] : nil
            var cited = seed?.sourceNumbers.filter(validNumbers.contains) ?? []
            if cited.isEmpty { cited = [sources[index].number] }
            let packetSources = sources.filter { cited.prefix(2).contains($0.number) }
            let packet = packetSources.map {
                "SOURCE [\($0.number)]\nTITLE: \($0.title)\nURL: \($0.url)\n\(String($0.text.prefix(7_000)))"
            }.joined(separator: "\n\n---\n\n")
            let seedDirection = seed.map {
                "A preliminary editor suggested this angle, but discard it if the sources do not support it: \($0.headline) - \($0.deck)"
            } ?? "Choose the most consequential, specific angle supported by this packet."
            let storySchema: [String: Any] = [
                "type": "object",
                "required": ["headline", "deck", "body", "keyPoints", "sourceNumbers"],
                "properties": [
                    "headline": ["type": "string"], "deck": ["type": "string"],
                    "body": ["type": "string"],
                    "keyPoints": ["type": "array", "items": ["type": "string"]],
                    "sourceNumbers": ["type": "array", "items": ["type": "integer"]]
                ]
            ]
            let payload: [String: Any] = [
                "model": model, "stream": false, "format": storySchema,
                "options": ["temperature": 0.2],
                "messages": [
                    ["role": "system", "content": "You are an exacting long-form news editor. Use only the supplied sources. Never invent events, people, statistics, dates, or quotations. Return JSON only."],
                    ["role": "user", "content": """
                    Write one substantial feature for a magazine about \(query).
                    \(seedDirection)
                    The body must be 550-850 words with context, competing interpretations when supported, consequences, and what to watch next. Cite only the supplied source numbers. Do not write a generic summary and do not mention these instructions.

                    \(packet)
                    """]
                ]
            ]
            if let content = try? await ollamaContent(payload),
               let story = Self.decodeStory(from: content),
               Self.wordCount(story.body) >= 350,
               !story.sourceNumbers.filter(validNumbers.contains).isEmpty {
                stories.append(story)
            } else {
                stories.append(Self.sourceLedStory(from: packetSources.first ?? sources[index]))
            }
        }
        issue.stories = stories
        if stories.allSatisfy({ $0.deck.contains("source-led briefing") }) {
            issue.editorNote = "This source-led edition preserves the depth of the retrieved reporting because the selected model did not reliably produce grounded long-form copy."
        }
        return issue
    }

    private func ollamaContent(_ payload: [String: Any]) async throws -> String {
        var httpRequest = HTTPClientRequest(url: upstream + "/api/chat")
        httpRequest.method = .POST
        httpRequest.headers.add(name: "content-type", value: "application/json")
        httpRequest.body = .bytes(ByteBuffer(bytes: try JSONSerialization.data(withJSONObject: payload)))
        let response = try await client.execute(httpRequest, timeout: .hours(1))
        let body = try await response.body.collect(upTo: 32 * 1024 * 1024)
        let data = Data(body.readableBytesView)
        guard (200..<300).contains(Int(response.status.code)) else {
            throw MagazineDigestError.ollama(Int(response.status.code), String(decoding: data, as: UTF8.self))
        }
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = envelope["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw MagazineDigestError.malformedEditorialOutput
        }
        return content
    }

    static func decodeIssue(from content: String) -> MagazineDigestIssue? {
        var candidates = [content.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let open = content.firstIndex(of: "{"), let close = content.lastIndex(of: "}"), open < close {
            candidates.append(String(content[open...close]))
        }
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8) else { continue }
            if let issue = try? JSONDecoder().decode(MagazineDigestIssue.self, from: data), !issue.stories.isEmpty {
                return issue
            }
            guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            Self.rename("editor_note", to: "editorNote", in: &object)
            if var stories = object["stories"] as? [[String: Any]] {
                for index in stories.indices {
                    Self.rename("key_points", to: "keyPoints", in: &stories[index])
                    Self.rename("source_numbers", to: "sourceNumbers", in: &stories[index])
                    if stories[index]["sourceNumbers"] == nil, let source = stories[index]["sources"] {
                        stories[index]["sourceNumbers"] = source
                    }
                }
                object["stories"] = stories
            }
            guard let normalized = try? JSONSerialization.data(withJSONObject: object),
                  let issue = try? JSONDecoder().decode(MagazineDigestIssue.self, from: normalized),
                  !issue.stories.isEmpty else { continue }
            return issue
        }
        return nil
    }

    static func decodeStory(from content: String) -> MagazineDigestStory? {
        var candidates = [content.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let open = content.firstIndex(of: "{"), let close = content.lastIndex(of: "}"), open < close {
            candidates.append(String(content[open...close]))
        }
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8) else { continue }
            if let story = try? JSONDecoder().decode(MagazineDigestStory.self, from: data) { return story }
            guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            Self.rename("key_points", to: "keyPoints", in: &object)
            Self.rename("source_numbers", to: "sourceNumbers", in: &object)
            if object["sourceNumbers"] == nil, let source = object["sources"] { object["sourceNumbers"] = source }
            guard let normalized = try? JSONSerialization.data(withJSONObject: object),
                  let story = try? JSONDecoder().decode(MagazineDigestStory.self, from: normalized) else { continue }
            return story
        }
        return nil
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private static func rename(_ old: String, to new: String, in object: inout [String: Any]) {
        if object[new] == nil, let value = object.removeValue(forKey: old) { object[new] = value }
    }

    static func sourceLedIssue(
        query: String, requestedTitle: String?, storyCount: Int, sources: [MagazineSource]
    ) -> MagazineDigestIssue {
        let selected = Array(sources.prefix(storyCount))
        let stories = selected.map(Self.sourceLedStory)
        return MagazineDigestIssue(
            title: requestedTitle?.nilIfEmpty ?? "The Morning Digest",
            subtitle: query,
            editorNote: "The selected model did not produce reliable structured editorial copy, so this edition uses concise source-led extracts with direct attribution.",
            stories: stories
        )
    }

    private static func sourceLedStory(from source: MagazineSource) -> MagazineDigestStory {
        let paragraphs = source.text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 80 && !$0.hasPrefix("#") && !$0.hasPrefix("-") }
        let body = paragraphs.prefix(10).joined(separator: "\n\n")
        return MagazineDigestStory(
            headline: source.title,
            deck: "A source-led briefing selected for its relevance to today's edition.",
            body: String((body.nilIfEmpty ?? source.text).prefix(6_500)),
            keyPoints: [], sourceNumbers: [source.number]
        )
    }
}

struct MagazinePDFRenderer {
    private let page = CGRect(x: 0, y: 0, width: 612, height: 792)
    private let ink = NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.13, alpha: 1).cgColor
    private let accent = NSColor(calibratedRed: 0.82, green: 0.25, blue: 0.16, alpha: 1).cgColor
    private let paper = NSColor(calibratedRed: 0.97, green: 0.95, blue: 0.90, alpha: 1).cgColor

    func render(issue: MagazineDigestIssue, sources: [MagazineSource], date: Date) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw MagazineDigestError.renderingFailed
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        drawCover(context, issue: issue, sources: sources, date: formatter.string(from: date))
        drawContents(context, issue: issue)
        var pageNumber = 3
        for (index, story) in issue.stories.enumerated() {
            let source = sources.first { story.sourceNumbers.contains($0.number) }
            pageNumber = drawStory(
                context, story: story, number: index + 1,
                startingPage: pageNumber, image: source?.imageData
            )
        }
        drawSources(context, sources: sources)
        context.closePDF()
        return data as Data
    }

    private func begin(_ context: CGContext, dark: Bool = false) {
        context.beginPDFPage([kCGPDFContextMediaBox as String: page] as CFDictionary)
        context.saveGState()
        context.setFillColor(dark ? ink : paper)
        context.fill(page)
    }

    private func end(_ context: CGContext, pageNumber: Int? = nil) {
        if let pageNumber {
            draw("\(pageNumber)", in: CGRect(x: 548, y: 25, width: 24, height: 14), context: context,
                 font: "HelveticaNeue-Medium", size: 9, color: ink, alignment: .right)
        }
        context.restoreGState()
        context.endPDFPage()
    }

    private func drawCover(_ context: CGContext, issue: MagazineDigestIssue, sources: [MagazineSource], date: String) {
        begin(context, dark: true)
        if let data = sources.compactMap(\.imageData).first, let image = cgImage(data) {
            drawImage(image, in: CGRect(x: 0, y: 250, width: 612, height: 542), context: context)
            context.setFillColor(NSColor.black.withAlphaComponent(0.46).cgColor)
            context.fill(CGRect(x: 0, y: 250, width: 612, height: 542))
        }
        context.setFillColor(accent)
        context.fill(CGRect(x: 42, y: 730, width: 88, height: 5))
        draw("MORNING EDITION", in: CGRect(x: 42, y: 700, width: 250, height: 22), context: context,
             font: "HelveticaNeue-Bold", size: 11, color: NSColor.white.cgColor)
        draw(issue.title.uppercased(), in: CGRect(x: 42, y: 490, width: 525, height: 190), context: context,
             font: "TimesNewRomanPS-BoldMT", size: 49, color: NSColor.white.cgColor)
        draw(issue.subtitle, in: CGRect(x: 45, y: 385, width: 500, height: 92), context: context,
             font: "HelveticaNeue", size: 18, color: NSColor.white.cgColor)
        draw(date.uppercased(), in: CGRect(x: 45, y: 52, width: 500, height: 20), context: context,
             font: "HelveticaNeue-Medium", size: 10, color: NSColor.white.cgColor)
        end(context)
    }

    private func drawContents(_ context: CGContext, issue: MagazineDigestIssue) {
        begin(context)
        sectionLabel("THE BRIEFING", context: context)
        draw("Inside today's edition", in: CGRect(x: 44, y: 635, width: 520, height: 80), context: context,
             font: "TimesNewRomanPS-BoldMT", size: 35, color: ink)
        draw(issue.editorNote, in: CGRect(x: 44, y: 505, width: 510, height: 110), context: context,
             font: "TimesNewRomanPSMT", size: 15, color: ink)
        var y: CGFloat = 450
        for (index, story) in issue.stories.enumerated() {
            draw(String(format: "%02d", index + 1), in: CGRect(x: 44, y: y, width: 38, height: 32), context: context,
                 font: "HelveticaNeue-Bold", size: 13, color: accent)
            draw(story.headline, in: CGRect(x: 95, y: y - 3, width: 455, height: 42), context: context,
                 font: "TimesNewRomanPS-BoldMT", size: 20, color: ink)
            y -= 67
        }
        end(context, pageNumber: 2)
    }

    private func drawStory(
        _ context: CGContext, story: MagazineDigestStory, number: Int,
        startingPage: Int, image: Data?
    ) -> Int {
        var pageNumber = startingPage
        begin(context)
        var headlineY: CGFloat = 580
        if let image, let cg = cgImage(image) {
            drawImage(cg, in: CGRect(x: 0, y: 535, width: 612, height: 257), context: context)
            context.setFillColor(NSColor.black.withAlphaComponent(0.38).cgColor)
            context.fill(CGRect(x: 0, y: 535, width: 612, height: 257))
            sectionLabel("FEATURE \(String(format: "%02d", number))", context: context, light: true)
            headlineY = 555
        } else {
            sectionLabel("FEATURE \(String(format: "%02d", number))", context: context)
        }
        draw(story.headline, in: CGRect(x: 44, y: headlineY, width: 520, height: 130), context: context,
             font: "TimesNewRomanPS-BoldMT", size: 34,
             color: image == nil ? ink : NSColor.white.cgColor)
        let deckY = image == nil ? 495 : 465
        draw(story.deck, in: CGRect(x: 45, y: deckY, width: 510, height: 62), context: context,
             font: "HelveticaNeue-Medium", size: 14, color: ink)
        let bodyTop = CGFloat(deckY - 18)
        var location = drawColumns(story.body, startingAt: 0, context: context, top: bodyTop, bottom: 70)
        let citations = story.sourceNumbers.sorted().map { "[\($0)]" }.joined(separator: " ")
        if location >= story.body.utf16.count {
            drawCitations(citations, context: context)
        } else {
            draw("CONTINUED", in: CGRect(x: 44, y: 43, width: 470, height: 15), context: context,
                 font: "HelveticaNeue-Bold", size: 8.5, color: accent)
        }
        end(context, pageNumber: pageNumber)
        pageNumber += 1

        while location < story.body.utf16.count {
            begin(context)
            sectionLabel("FEATURE \(String(format: "%02d", number)) / CONTINUED", context: context)
            draw(story.headline, in: CGRect(x: 44, y: 665, width: 520, height: 55), context: context,
                 font: "TimesNewRomanPS-BoldMT", size: 22, color: ink)
            let nextLocation = drawColumns(
                story.body, startingAt: location, context: context, top: 640, bottom: 70
            )
            if nextLocation >= story.body.utf16.count {
                drawCitations(citations, context: context)
            } else {
                draw("CONTINUED", in: CGRect(x: 44, y: 43, width: 470, height: 15), context: context,
                     font: "HelveticaNeue-Bold", size: 8.5, color: accent)
            }
            end(context, pageNumber: pageNumber)
            pageNumber += 1
            guard nextLocation > location else { break }
            location = nextLocation
        }
        return pageNumber
    }

    private func drawCitations(_ citations: String, context: CGContext) {
        draw("SOURCES \(citations)", in: CGRect(x: 44, y: 43, width: 470, height: 15), context: context,
             font: "HelveticaNeue-Bold", size: 8.5, color: accent)
    }

    private func drawSources(_ context: CGContext, sources: [MagazineSource]) {
        begin(context, dark: true)
        sectionLabel("SOURCES & METHOD", context: context, light: true)
        draw("Reporting notes", in: CGRect(x: 44, y: 645, width: 520, height: 70), context: context,
             font: "TimesNewRomanPS-BoldMT", size: 36, color: NSColor.white.cgColor)
        draw("This edition was synthesized by a local Ollama model from the sources below. Links are printed in full for transparency; publisher images remain attributed to their originating pages.",
             in: CGRect(x: 44, y: 555, width: 510, height: 72), context: context,
             font: "HelveticaNeue", size: 12, color: NSColor.white.cgColor)
        var y: CGFloat = 515
        for source in sources.prefix(10) {
            draw("[\(source.number)] \(source.title)", in: CGRect(x: 44, y: y, width: 520, height: 28), context: context,
                 font: "HelveticaNeue-Bold", size: 10.5, color: NSColor.white.cgColor)
            draw(source.url, in: CGRect(x: 44, y: y - 18, width: 520, height: 20), context: context,
                 font: "HelveticaNeue", size: 7.5, color: NSColor(calibratedWhite: 0.76, alpha: 1).cgColor)
            y -= 52
            if y < 60 { break }
        }
        end(context)
    }

    private func sectionLabel(_ text: String, context: CGContext, light: Bool = false) {
        context.setFillColor(accent)
        context.fill(CGRect(x: 44, y: 742, width: 54, height: 4))
        draw(text, in: CGRect(x: 108, y: 734, width: 360, height: 18), context: context,
             font: "HelveticaNeue-Bold", size: 9, color: light ? NSColor.white.cgColor : ink)
    }

    private func drawColumns(
        _ text: String, startingAt initialLocation: Int,
        context: CGContext, top: CGFloat, bottom: CGFloat
    ) -> Int {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont(name: "TimesNewRomanPSMT", size: 11.5) ?? .systemFont(ofSize: 11.5),
            .foregroundColor: NSColor(cgColor: ink) ?? .black,
            .paragraphStyle: paragraphStyle()
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var location = initialLocation
        for x: CGFloat in [44, 316] {
            let rect = CGRect(x: x, y: bottom, width: 252, height: max(40, top - bottom))
            let path = CGPath(rect: rect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            location += visible.length
            if visible.length == 0 || location >= attributed.length { break }
        }
        return location
    }

    private func draw(_ text: String, in rect: CGRect, context: CGContext, font: String, size: CGFloat, color: CGColor, alignment: CTTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment == .right ? .right : .left
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont(name: font, size: size) ?? .systemFont(ofSize: size),
            .foregroundColor: NSColor(cgColor: color) ?? .black,
            .paragraphStyle: paragraph
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, context)
    }

    private func paragraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = 8
        style.hyphenationFactor = 0.35
        return style
    }

    private func cgImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        let sourceAspect = CGFloat(image.width) / CGFloat(image.height)
        let targetAspect = rect.width / rect.height
        var crop = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        if sourceAspect > targetAspect {
            let width = CGFloat(image.height) * targetAspect
            crop.origin.x = (CGFloat(image.width) - width) / 2
            crop.size.width = width
        } else {
            let height = CGFloat(image.width) / targetAspect
            crop.origin.y = (CGFloat(image.height) - height) / 2
            crop.size.height = height
        }
        if let cropped = image.cropping(to: crop) { context.draw(cropped, in: rect) }
    }
}
