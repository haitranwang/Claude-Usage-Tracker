import XCTest
@testable import Claude_Usage

private final class StubInput: TokenStatsInputProviding {
    var enabledTokenFrames: Set<MenuBarMetricType> = [.tokens7Days]
    var countCacheTokens: Bool = true
}

/// The loader closure runs on a background queue, so counters it touches need their own lock.
private final class Counter {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock(); count += 1; lock.unlock()
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }; return count
    }
}

private final class FlagBox {
    private let lock = NSLock()
    private var flag: Bool?

    func set(_ newValue: Bool) {
        lock.lock(); flag = newValue; lock.unlock()
    }

    var value: Bool? {
        lock.lock(); defer { lock.unlock() }; return flag
    }
}

private final class RecordingDelegate: TokenStatsRefreshCoordinatorDelegate {
    var received: [TokenStats] = []
    /// Fulfilled once per delivery. `assertForOverFulfill` is left on by the caller where a
    /// second delivery would be a bug, and the expectation is swapped rather than re-fulfilled.
    var expectation: XCTestExpectation?

    init(expectation: XCTestExpectation? = nil) {
        self.expectation = expectation
    }

    func tokenStatsCoordinator(_ coordinator: TokenStatsRefreshCoordinator, didLoad stats: TokenStats) {
        received.append(stats)
        expectation?.fulfill()
    }
}

final class TokenStatsRefreshCoordinatorTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenCoordTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        try super.tearDownWithError()
    }

    private func makeCoordinator(
        input: StubInput,
        delegate: RecordingDelegate,
        loader: @escaping (Set<MenuBarMetricType>, Bool) -> TokenStats
    ) -> TokenStatsRefreshCoordinator {
        let c = TokenStatsRefreshCoordinator(load: loader)
        c.input = input
        c.delegate = delegate
        return c
    }

    func testRefreshDeliversStatsToDelegate() {
        let expectation = expectation(description: "delegate called")
        let delegate = RecordingDelegate(expectation: expectation)
        // `coordinator.input` is weak (matches production, where the owner holds the strong
        // reference), so the stub needs a local strong reference to survive past this call.
        let input = StubInput()
        let coordinator = makeCoordinator(input: input, delegate: delegate) { _, _ in
            TokenStats(allTime: 42, last7Days: 7, last30Days: 30, isAvailable: true)
        }

        coordinator.refreshNow()

        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(delegate.received.first?.allTime, 42)
    }

    func testCoordinatorSkipsTickWhileScanning() {
        // A scan that outlives its own interval must not start a second one alongside it.
        // Two concurrent scans each hold hundreds of MB of mapped JSONL.
        let started = expectation(description: "first load started")
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "first load delivered")
        let delegate = RecordingDelegate(expectation: finished)

        let counter = Counter()

        // See testRefreshDeliversStatsToDelegate: `coordinator.input` is weak, so the stub
        // needs a local strong reference to survive past the makeCoordinator call.
        let input = StubInput()
        let coordinator = makeCoordinator(input: input, delegate: delegate) { _, _ in
            counter.increment()
            started.fulfill()
            release.wait()
            return .unavailable
        }

        coordinator.refreshNow()
        wait(for: [started], timeout: 5)

        // While the first load is parked inside the loader, fire several more.
        coordinator.refreshNow()
        coordinator.refreshNow()
        coordinator.refreshNow()

        XCTAssertTrue(coordinator.isLoading, "guard must report a scan in flight")
        release.signal()
        wait(for: [finished], timeout: 5)

        XCTAssertEqual(counter.value, 1, "overlapping refreshes must be dropped, not queued")
        XCTAssertFalse(coordinator.isLoading, "guard must clear once the scan finishes")
    }

    func testRefreshAfterCompletionRunsAgain() {
        // Dropping overlapping ticks must not wedge the coordinator permanently.
        let first = expectation(description: "first")
        let delegate = RecordingDelegate(expectation: first)
        let counter = Counter()

        // See testRefreshDeliversStatsToDelegate: `coordinator.input` is weak, so the stub
        // needs a local strong reference to survive past the makeCoordinator call.
        let input = StubInput()
        let coordinator = makeCoordinator(input: input, delegate: delegate) { _, _ in
            counter.increment()
            return .unavailable
        }

        coordinator.refreshNow()
        wait(for: [first], timeout: 5)

        // Swap in a fresh expectation rather than re-fulfilling the satisfied one, which
        // XCTest treats as an API violation.
        let second = expectation(description: "second")
        delegate.expectation = second
        coordinator.refreshNow()
        wait(for: [second], timeout: 5)

        XCTAssertEqual(counter.value, 2)
    }

    func testNoTokenFramesEnabledSkipsLoadEntirely() {
        let input = StubInput()
        input.enabledTokenFrames = []
        let done = expectation(description: "delivered")
        let delegate = RecordingDelegate(expectation: done)
        let counter = Counter()

        let coordinator = makeCoordinator(input: input, delegate: delegate) { _, _ in
            counter.increment()
            return .unavailable
        }

        coordinator.refreshNow()
        wait(for: [done], timeout: 5)

        XCTAssertEqual(counter.value, 0, "no enabled token frames means no scan at all")
        XCTAssertEqual(delegate.received.first, .unavailable)
    }

    func testCountCacheTokensIsForwardedToLoader() {
        let input = StubInput()
        input.countCacheTokens = false
        let done = expectation(description: "delivered")
        let delegate = RecordingDelegate(expectation: done)
        let box = FlagBox()

        let coordinator = makeCoordinator(input: input, delegate: delegate) { _, countCache in
            box.set(countCache)
            return .unavailable
        }

        coordinator.refreshNow()
        wait(for: [done], timeout: 5)

        XCTAssertEqual(box.value, false)
    }
}
