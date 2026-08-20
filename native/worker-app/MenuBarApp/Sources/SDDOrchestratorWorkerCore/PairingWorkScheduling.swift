import Foundation

/// Where `PairingFlowController` runs its self-report gathering (which
/// shells out to `bin/worker eval`) and network POST — off whatever thread
/// `handle(urlString:)` was called from (the Apple Event handler runs on
/// the main thread; this must not block it). A seam purely so tests can
/// substitute a synchronous scheduler and assert results without timing or
/// `XCTestExpectation`.
public protocol PairingWorkScheduling {
    func schedule(_ work: @escaping () -> Void)
}

/// The production `PairingWorkScheduling` implementation: a real background
/// `DispatchQueue`.
public struct DispatchQueueScheduler: PairingWorkScheduling {
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = DispatchQueue(label: "com.sddorchestrator.worker.pairing", qos: .userInitiated)) {
        self.queue = queue
    }

    public func schedule(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }
}
