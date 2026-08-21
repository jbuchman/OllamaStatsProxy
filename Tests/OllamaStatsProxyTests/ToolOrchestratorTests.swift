import Testing
@testable import OllamaStatsProxy

@Test func webToolRelevanceLeavesSelfContainedCodingPromptsTransparent() {
    let codingPrompt: [String: Any] = [
        "messages": [[
            "role": "user",
            "content": "Given url(#paint14_radial_13003_106798), append _red using JavaScript"
        ]]
    ]
    #expect(!ToolOrchestrator.appearsToNeedWebTools(codingPrompt))
}

@Test func webToolRelevanceRecognizesSearchURLsAndMultimodalText() {
    let searchPrompt: [String: Any] = [
        "messages": [["role": "user", "content": "Search the web for the latest Swift release notes"]]
    ]
    let urlPrompt: [String: Any] = [
        "messages": [["role": "user", "content": "Read https://swift.org/blog and summarize it"]]
    ]
    let multimodalPrompt: [String: Any] = [
        "messages": [["role": "user", "content": [["type": "text", "text": "Provide sources for this claim"]]]]
    ]
    #expect(ToolOrchestrator.appearsToNeedWebTools(searchPrompt))
    #expect(ToolOrchestrator.appearsToNeedWebTools(urlPrompt))
    #expect(ToolOrchestrator.appearsToNeedWebTools(multimodalPrompt))
}
