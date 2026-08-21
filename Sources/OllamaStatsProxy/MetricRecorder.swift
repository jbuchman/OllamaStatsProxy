import Foundation

enum MetricEvent: Sendable {
    case count(Int64, CountEvent)
    case finish(Int64, String?)
}

/// A non-blocking handoff between the byte-forwarding hot path and metrics storage.
/// AsyncStream preserves event order while `yield` returns synchronously.
final class MetricRecorder: @unchecked Sendable {
    private let continuation: AsyncStream<MetricEvent>.Continuation
    private let worker: Task<Void, Never>

    init(store: StatsStore) {
        let (stream, continuation) = AsyncStream<MetricEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.continuation = continuation
        self.worker = Task {
            for await event in stream {
                switch event {
                case .count(let requestID, .token):
                    await store.streamedToken(requestID: requestID)
                case .count(let requestID, .done(let metrics)):
                    await store.reconcile(requestID: requestID, metrics: metrics)
                case .finish(let requestID, let error):
                    try? await store.finish(requestID: requestID, error: error)
                }
            }
        }
    }

    func record(_ event: MetricEvent) {
        continuation.yield(event)
    }

    deinit {
        continuation.finish()
        worker.cancel()
    }
}
