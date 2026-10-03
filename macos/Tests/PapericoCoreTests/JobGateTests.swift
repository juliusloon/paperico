import XCTest
@testable import PapericoCore

private actor WorkCounter {
    var running = 0
    var peak = 0
    func enter() { running += 1; peak = max(peak, running) }
    func leave() { running -= 1 }
}

final class JobGateTests: XCTestCase {
    func testParallelWorkRespectsLimit() async throws {
        let gate = JobGate(limit: 2)
        let counter = WorkCounter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    try await gate.withPermit {
                        await counter.enter()
                        try await Task.sleep(for: .milliseconds(5))
                        await counter.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        let peak = await counter.peak
        let running = await counter.running
        XCTAssertEqual(peak, 2)
        XCTAssertEqual(running, 0)
    }

    func testCancelledQueueEntryDoesNotConsumeNextPermit() async throws {
        let gate = JobGate(limit: 1)
        try await gate.acquire()
        let cancelled = Task { try await gate.acquire() }
        try await Task.sleep(for: .milliseconds(20))
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Queued acquisition should throw on cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        await gate.release()
        let result = try await gate.withPermit { 42 }
        XCTAssertEqual(result, 42)
    }

    func testThrowingOperationReleasesPermit() async throws {
        let gate = JobGate(limit: 1)
        do { try await gate.withPermit { throw PipelineError("failed") } }
        catch { XCTAssertTrue(error is PipelineError) }
        let result = try await gate.withPermit { "next" }
        XCTAssertEqual(result, "next")
    }
}
