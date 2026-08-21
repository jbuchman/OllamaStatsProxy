import Foundation
import Testing
@testable import OllamaStatsProxy

@Test func activeRequestRegistryRemembersAndInvokesCancellation() async {
    let registry = ActiveRequestRegistry()
    let marker = CancellationMarker()

    await registry.begin(42)
    #expect(await registry.cancel(42) == .cancelled)
    await registry.install(42) { marker.mark() }
    #expect(marker.value)
    #expect(await registry.wasCancellationRequested(42))
    #expect(await registry.cancel(42) == .alreadyRequested)

    await registry.finish(42)
    #expect(await registry.cancel(42) == .notActive)
}

private final class CancellationMarker: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false

    var value: Bool { lock.withLock { marked } }
    func mark() { lock.withLock { marked = true } }
}
