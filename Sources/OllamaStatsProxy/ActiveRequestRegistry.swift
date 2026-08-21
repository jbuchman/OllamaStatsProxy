import Foundation

actor ActiveRequestRegistry {
    static let cancellationReason = "cancelled by administrator"

    enum CancelResult: Sendable, Equatable {
        case cancelled
        case alreadyRequested
        case notActive
    }

    private struct Entry: Sendable {
        var cancel: (@Sendable () -> Void)?
        var cancellationRequested = false
    }

    private var entries: [Int64: Entry] = [:]

    func begin(_ requestID: Int64) {
        entries[requestID] = Entry()
    }

    /// Replaces the cancellable operation as a request moves from connection setup
    /// to response streaming. A cancellation arriving between phases is remembered.
    func install(_ requestID: Int64, cancel: @escaping @Sendable () -> Void) {
        guard var entry = entries[requestID] else {
            cancel()
            return
        }
        entry.cancel = cancel
        entries[requestID] = entry
        if entry.cancellationRequested { cancel() }
    }

    func cancel(_ requestID: Int64) -> CancelResult {
        guard var entry = entries[requestID] else { return .notActive }
        guard !entry.cancellationRequested else { return .alreadyRequested }
        entry.cancellationRequested = true
        entries[requestID] = entry
        entry.cancel?()
        return .cancelled
    }

    func wasCancellationRequested(_ requestID: Int64) -> Bool {
        entries[requestID]?.cancellationRequested == true
    }

    func finish(_ requestID: Int64) {
        entries.removeValue(forKey: requestID)
    }
}

struct CancelRequestResponse: Codable, Sendable {
    var requestID: Int64
    var status: String
}
