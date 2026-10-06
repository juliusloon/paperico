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

    /// T3: local MinerU is one service on one machine, so it must be serialized;
    /// cloud parsing and model calls are remote and stay concurrent.
    func testLocalParseIsSerializedWhileCloudAndLLMStayConcurrent() async throws {
        XCTAssertEqual(JobGateLimit.localParse, 1)
        XCTAssertEqual(JobGateLimit.cloudParse, 2)
        XCTAssertEqual(JobGateLimit.llm, 2)

        let localGate = JobGate(limit: JobGateLimit.localParse)
        let cloudGate = JobGate(limit: JobGateLimit.cloudParse)
        let localCounter = WorkCounter()
        let cloudCounter = WorkCounter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try await localGate.withPermit {
                        await localCounter.enter()
                        try await Task.sleep(for: .milliseconds(5))
                        await localCounter.leave()
                    }
                }
                group.addTask {
                    try await cloudGate.withPermit {
                        await cloudCounter.enter()
                        try await Task.sleep(for: .milliseconds(5))
                        await cloudCounter.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        let localPeak = await localCounter.peak
        let cloudPeak = await cloudCounter.peak
        XCTAssertEqual(localPeak, 1, "Local MinerU must parse one paper at a time")
        XCTAssertEqual(cloudPeak, 2)
        let localCapacity = await localGate.capacity
        let cloudCapacity = await cloudGate.capacity
        XCTAssertEqual(localCapacity, 1)
        XCTAssertEqual(cloudCapacity, 2)
    }
}
