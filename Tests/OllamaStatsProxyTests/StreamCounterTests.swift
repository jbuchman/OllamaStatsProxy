import Foundation
import Testing
@testable import OllamaStatsProxy

@Suite struct StreamCounterTests {
    @Test func countsSplitNDJSONAndReconciles() {
        var counter = StreamCounter(format: .ndjson)
        #expect(counter.consume(Array(#"{"response":"a","done":false}"#.utf8)) == [])
        #expect(counter.consume(Array("\n".utf8)) == [.token])
        #expect(counter.consume(Array(#"{"done":true,"eval_count":7,"prompt_eval_count":3}"#.utf8)) == [])
        #expect(counter.finish() == [.done(FinalMetrics(outputTokens: 7, promptTokens: 3))])
    }

    @Test func countsSSEReasoningAndDone() {
        var counter = StreamCounter(format: .sse)
        let data = "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"hmm\"}}]}\n\ndata: [DONE]\n\n"
        #expect(counter.consume(Array(data.utf8)) == [.token, .done(FinalMetrics())])
    }

    @Test func readsNonStreamingUsage() {
        var counter = StreamCounter(format: .json)
        _ = counter.consume(Array(#"{"usage":{"prompt_tokens":11,"completion_tokens":13}}"#.utf8))
        #expect(counter.finish() == [.done(FinalMetrics(outputTokens: 13, promptTokens: 11))])
    }

    @Test func readsOllamaDurations() {
        let json = #"{"done":true,"eval_count":20,"prompt_eval_count":10,"total_duration":4000000000,"load_duration":100000000,"prompt_eval_duration":500000000,"eval_duration":2000000000}"#
        let expected = CountEvent.done(FinalMetrics(
            outputTokens: 20, promptTokens: 10,
            totalDurationNanoseconds: 4_000_000_000, loadDurationNanoseconds: 100_000_000,
            promptEvalDurationNanoseconds: 500_000_000, evalDurationNanoseconds: 2_000_000_000
        ))
        #expect(StreamCounter.parseLine(Data(json.utf8), format: .ndjson) == expected)
    }
}
