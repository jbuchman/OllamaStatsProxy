import Foundation
import Testing
@testable import OllamaStatsProxy

@Test func htmlConversionPreservesStructureAndResolvesLinks() {
    let html = """
        <html><head><script>ignore me</script></head><body>
        <h1>News &amp; analysis</h1>
        <p>Read <a href="/articles/story?id=7&amp;src=home"><b>the story</b></a>.</p>
        <ul><li>First item</li><li>Second item</li></ul>
        <pre>let x = 1 &lt; 2</pre>
        </body></html>
        """
    let markdown = WebTools.markdownText(html, baseURL: URL(string: "https://example.com/search")!)

    #expect(markdown.contains("# News & analysis"))
    #expect(markdown.contains("[the story](https://example.com/articles/story?id=7&src=home)"))
    #expect(markdown.contains("- First item"))
    #expect(markdown.contains("```\nlet x = 1 < 2\n```"))
    #expect(!markdown.contains("ignore me"))
}

@Test func openGraphImageIsResolvedAgainstArticleURL() {
    let html = #"<html><head><meta property="og:image" content="/media/lead.jpg"></head></html>"#
    let image = WebTools.extractImageURL(html, baseURL: URL(string: "https://news.example/story/1")!)
    #expect(image == "https://news.example/media/lead.jpg")
}

@Test func configurationPersistsAndRedactsAPIKey() async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("ollama-config-\(UUID().uuidString).json").path
    let defaults = AppConfiguration(
        webSearchProvider: .brave, webSearchAPIKey: "secret", webSearchURL: nil,
        webFetchMaxBytes: 8 * 1024 * 1024, webFetchMaxCharacters: 50_000,
        webFetchEnabled: true, webFetchAllowPrivateNetworks: false,
        serverToolsEnabled: true, serverToolRounds: 4,
        adminPasswordHash: nil
    )
    let file = try ConfigurationFile(path: path, defaults: defaults)
    let initial = await file.view()
    #expect(initial.webSearchAPIKeyConfigured)

    _ = try await file.update(ConfigurationUpdate(
        webSearchProvider: .tavily, webSearchAPIKey: nil, clearWebSearchAPIKey: false,
        webSearchURL: " https://example.com/search ", webFetchMaxMB: 12,
        webFetchMaxCharacters: 80_000, webFetchEnabled: false,
        webFetchAllowPrivateNetworks: false,
        serverToolsEnabled: true, serverToolRounds: 6,
        adminPassword: nil
    ))
    let reloaded = try ConfigurationFile(path: path, defaults: defaults)
    let value = await reloaded.value()
    #expect(value.webSearchProvider == .tavily)
    #expect(value.webSearchAPIKey == "secret")
    #expect(value.webSearchURL == "https://example.com/search")
    #expect(value.webFetchMaxBytes == 12 * 1024 * 1024)
    #expect(value.webFetchEnabled == false)

    let passwordConfigured = try ConfigurationFile(
        path: path, defaults: defaults, adminPasswordOverride: "new admin password"
    )
    let secured = await passwordConfigured.value()
    #expect(secured.adminPasswordHash != nil)
    #expect(PasswordHasher.verify("new admin password", encoded: secured.adminPasswordHash!))
}

@Test func passwordHashIsSaltedAndVerifiable() {
    let first = PasswordHasher.hash("correct horse battery staple")
    let second = PasswordHasher.hash("correct horse battery staple")
    #expect(first != second)
    #expect(PasswordHasher.verify("correct horse battery staple", encoded: first))
    #expect(!PasswordHasher.verify("wrong password", encoded: first))
}

@Test func urlSafetyRejectsNonPublicNetworks() async {
    #expect(!URLSafety.isPublic([127, 0, 0, 1]))
    #expect(!URLSafety.isPublic([10, 1, 2, 3]))
    #expect(!URLSafety.isPublic([169, 254, 169, 254]))
    #expect(!URLSafety.isPublic([192, 168, 1, 10]))
    #expect(!URLSafety.isPublic([203, 0, 113, 5]))
    #expect(URLSafety.isPublic([93, 184, 216, 34]))
    #expect(!URLSafety.isPublic([UInt8](repeating: 0, count: 15) + [1]))

    await #expect(throws: URLSafetyError.self) {
        try await URLSafety.validate(URL(string: "http://localhost/private")!, allowPrivateNetworks: false)
    }
    await #expect(throws: Never.self) {
        try await URLSafety.validate(URL(string: "http://localhost/private")!, allowPrivateNetworks: true)
    }
}
