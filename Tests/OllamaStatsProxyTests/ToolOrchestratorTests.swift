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

@Test func recentQuestionWithInternetPermissionRequiresWebResearch() {
    let prompt: [String: Any] = [
        "messages": [[
            "role": "user",
            "content": "Is there a recent Linux distro with up to date pre configured GNUstep and Window Maker? (Feel free to use the internet)"
        ]]
    ]
    #expect(ToolOrchestrator.appearsToNeedWebTools(prompt))
    #expect(ToolOrchestrator.requiresWebResearch(prompt))
}

@Test func internetAndCurrentDateCorrectionRequiresWebResearch() {
    let prompt: [String: Any] = [
        "messages": [[
            "role": "user",
            "content": "Not only do you have access to the internet, but you're confused about the current date (Aug 21, 2026)."
        ]]
    ]
    #expect(ToolOrchestrator.appearsToNeedWebTools(prompt))
    #expect(ToolOrchestrator.requiresWebResearch(prompt))
}
