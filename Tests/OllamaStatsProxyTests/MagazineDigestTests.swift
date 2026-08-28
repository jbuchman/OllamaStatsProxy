import Foundation
import CoreGraphics
import Testing
@testable import OllamaStatsProxy

@Test func magazineRendererProducesMultipagePDF() throws {
    let body = """
    The morning begins with a question that looks simple until the evidence is placed side by side. New developments have changed the near-term picture, while the longer trend remains contested among researchers, policymakers, and industry leaders.

    The available reporting agrees on the central facts but differs in emphasis. One source focuses on what happened, another adds historical context, and a third examines the practical consequences. Taken together, they offer a more useful account than any single headline.

    What matters next is execution. Announcements can establish direction, but measurable results will determine whether today's change becomes durable. Readers should watch the next set of public data and the response from affected communities.
    """
    let issue = MagazineDigestIssue(
        title: "The Morning Ledger",
        subtitle: "A considered briefing on the forces shaping the day",
        editorNote: "Today's edition follows the facts across technology, public policy, and the choices that connect them.",
        stories: (1...3).map { number in
            MagazineDigestStory(
                headline: "A consequential shift comes into focus \(number)",
                deck: "The immediate news is only the beginning; the deeper story is how institutions respond.",
                body: body, keyPoints: ["Watch the evidence", "Compare the incentives"],
                sourceNumbers: [number]
            )
        }
    )
    let sources = (1...3).map { number in
        MagazineSource(
            number: number, title: "Example reporting \(number)",
            url: "https://example.com/reporting/\(number)", text: body,
            imageURL: nil, imageData: nil
        )
    }
    let pdf = try MagazinePDFRenderer().render(issue: issue, sources: sources, date: Date(timeIntervalSince1970: 1_756_368_000))
    #expect(pdf.starts(with: Data("%PDF".utf8)))
    #expect(pdf.count > 10_000)
    if let output = ProcessInfo.processInfo.environment["MAGAZINE_SAMPLE_OUTPUT"] {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: output).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try pdf.write(to: URL(fileURLWithPath: output))
    }
}

@Test func magazineDecoderAcceptsFencedSnakeCaseJSON() {
    let content = """
    Here is the requested edition:
    ```json
    {"title":"Daily","subtitle":"News","editor_note":"Context","stories":[{"headline":"Lead","deck":"Dek","body":"Body","key_points":["One"],"source_numbers":[1]}]}
    ```
    """
    let issue = MagazineDigestService.decodeIssue(from: content)
    #expect(issue?.editorNote == "Context")
    #expect(issue?.stories.first?.sourceNumbers == [1])
}

@Test func sourceLedFallbackCreatesAnIssueWhenStructuredOutputFails() {
    let source = MagazineSource(
        number: 1, title: "A reported development", url: "https://example.com/story",
        text: "This paragraph contains enough reporting detail to become a useful source-led briefing when a small local model cannot reliably produce the requested structured output. It remains directly attributed to the publisher.",
        imageURL: nil, imageData: nil
    )
    let issue = MagazineDigestService.sourceLedIssue(
        query: "Today's developments", requestedTitle: nil, storyCount: 3, sources: [source]
    )
    #expect(issue.title == "The Morning Digest")
    #expect(issue.stories.first?.sourceNumbers == [1])
    #expect(issue.stories.first?.body.contains("reporting detail") == true)
}

@Test func magazineDecoderAcceptsADeepStoryObject() {
    let content = """
    ```json
    {"headline":"A grounded feature","deck":"Why it matters","body":"Detailed reporting belongs here.","key_points":["Context"],"source_numbers":[2,3]}
    ```
    """
    let story = MagazineDigestService.decodeStory(from: content)
    #expect(story?.headline == "A grounded feature")
    #expect(story?.sourceNumbers == [2, 3])
}

@Test func magazineDiscoveryPromotesArticlesAndDropsNavigation() {
    let markdown = """
    - [Technology](https://example.com/technology/)
    [A detailed investigation into an important new development](https://example.com/2026/08/28/important-new-development/)
    [About this publication](https://example.com/about/)
    """
    let links = MagazineDigestService.articleLinks(in: markdown)
    #expect(links == ["https://example.com/2026/08/28/important-new-development/"])

    let cleaned = MagazineDigestService.cleanArticleText("""
    - [Markets](https://example.com/markets/)
    [The reported finding has meaningful consequences for the industry and its customers.](https://example.com/story)
    This paragraph provides enough substantive detail to remain in the cleaned article body for editorial use.
    """)
    #expect(!cleaned.contains("https://"))
    #expect(!cleaned.contains("Markets"))
    #expect(cleaned.contains("substantive detail"))
}

@Test func longMagazineStoriesFlowOntoContinuationPages() throws {
    let paragraph = "The evidence adds context, consequences, competing interpretations, and specific details that readers need in order to understand why this development matters and what they should watch next. "
    let ending = "FINAL_SENTENCE_MUST_SURVIVE_PAGINATION"
    let issue = MagazineDigestIssue(
        title: "Depth Test", subtitle: "A complete edition", editorNote: "No truncation.",
        stories: [MagazineDigestStory(
            headline: "A feature too substantial for a single page", deck: "The renderer must continue until the complete article has been drawn.",
            body: String(repeating: paragraph, count: 90) + ending,
            keyPoints: [], sourceNumbers: [1]
        )]
    )
    let source = MagazineSource(
        number: 1, title: "Source", url: "https://example.com/story",
        text: paragraph, imageURL: nil, imageData: nil
    )
    let pdf = try MagazinePDFRenderer().render(issue: issue, sources: [source], date: Date())
    let provider = CGDataProvider(data: pdf as CFData)
    let document = provider.flatMap(CGPDFDocument.init)
    #expect((document?.numberOfPages ?? 0) >= 5)
    if let output = ProcessInfo.processInfo.environment["MAGAZINE_LONG_SAMPLE_OUTPUT"] {
        try pdf.write(to: URL(fileURLWithPath: output))
    }
}
