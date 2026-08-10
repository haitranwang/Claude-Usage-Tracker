import XCTest
@testable import Claude_Usage

/// `TokenStatsInputProviding` is `@MainActor`, matching production where the real implementation
/// is main-actor state (the active profile's icon config).
@MainActor
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

    /// Increments and returns the new value atomically, so a caller can tell which call number
    /// it is (e.g. "am I the first invocation?") without a separate read racing the increment.
    @discardableResult
    func incrementAndGet() -> Int {
        lock.lock(); defer { lock.unlock() }; count += 1; return count
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
    /// Callers expecting more than one delivery (e.g. a coalesced follow-up) instead set
    /// `expectedFulfillmentCount` on the expectation itself.
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

    @MainActor
    func testRefreshDeliversStatsToDelegate() {
        let expectation = expectation(description: "delegate called")
        let delegate = RecordingDelegate(expectation: expectation)
        // `coordinator.input`/`delegate` are weak (matches production, where the owner holds
        // the strong reference); `withExtendedLifetime` keeps these locals alive for the whole
        // test rather than only until their last textual use, which under optimisation is not
        // guaranteed to be the end of the scope.
        let input = StubInput()
        withExtendedLifetime((input, delegate)) {
            let coordinator = makeCoordinator(input: input, delegate: delegate) { _, _ in
                TokenStats(allTime: 42, last7Days: 7, last30Days: 30, isAvailable: true)
            }

            coordinator.refreshNow()

            wait(for: [expectation], timeout: 5)
            XCTAssertEqual(delegate.received.first?.allTime, 42)
        }
    }

    @MainActor
    func testOverlappingRefreshesCoalesceIntoOneFollowUpScan() {
        // A scan that outlives its own interval must not start a second one alongside it, but
        // overlapping refreshNow() calls must not be lost either: several arriving mid-scan
        // must produce exactly one follow-up once the in-flight scan clears - not zero (dropped)
        // and not three (queued).
        let firstStarted = expectation(description: "first scan started")
        let release = DispatchSemaphore(value: 0)
        let bothDelivered = expectation(description: "first scan and its one follow-up delivered")
        bothDelivered.expectedFulfillmentCount = 2
        let delegate = RecordingDelegate(expectation: bothDelivered)
        let counter = Counter()
        let input = StubInput()

        withExtendedLifetime((input, delegate)) {
            let coordinator = makeCoordinator(input: input, delegate: delegate) { _, _ in
                let callNumber = counter.incrementAndGet()
                if callNumber == 1 {
                    firstStarted.fulfill()
                    release.wait()
                }
                return .unavailable
            }

            coordinator.refreshNow()
            wait(for: [firstStarted], timeout: 5)

            // While the first scan is parked inside the loader, fire several more.
            coordinator.refreshNow()
            coordinator.refreshNow()
            coordinator.refreshNow()

            XCTAssertTrue(coordinator.isLoading, "guard must report a scan in flight")
            XCTAssertEqual(counter.value, 1, "no follow-up may start until the in-flight scan clears")

            release.signal()
            wait(for: [bothDelivered], timeout: 5)

            XCTAssertEqual(
                counter.value, 2,
                "several overlapping refreshes must coalesce into exactly one follow-up scan"
            )
            XCTAssertFalse(coordinator.isLoading, "guard must clear once the follow-up finishes")
        }
    }

    @MainActor
    func testRefreshAfterCompletionRunsAgain() {
        // Sequential (non-overlapping) refreshes must not wedge the coordinator.
        let first = expectation(description: "first")
        let delegate = RecordingDelegate(expectation: first)
        let counter = Counter()
        let input = StubInput()

        withExtendedLifetime((input, delegate)) {
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
    }

    @MainActor
    func testNoTokenFramesEnabledSkipsLoadEntirely() {
        let input = StubInput()
        input.enabledTokenFrames = []
        let done = expectation(description: "delivered")
        let delegate = RecordingDelegate(expectation: done)
        let counter = Counter()

        withExtendedLifetime((input, delegate)) {
            let coordinator = makeCoordinator(input: input, delegate: delegate) { _, _ in
                counter.increment()
                return .unavailable
            }

            coordinator.refreshNow()
            wait(for: [done], timeout: 5)

            XCTAssertEqual(counter.value, 0, "no enabled token frames means no scan at all")
            XCTAssertEqual(delegate.received.first, .unavailable)
        }
    }

    @MainActor
    func testCountCacheTokensIsForwardedToLoader() {
        let input = StubInput()
        input.countCacheTokens = false
        let done = expectation(description: "delivered")
        let delegate = RecordingDelegate(expectation: done)
        let box = FlagBox()

        withExtendedLifetime((input, delegate)) {
            let coordinator = makeCoordinator(input: input, delegate: delegate) { _, countCache in
                box.set(countCache)
                return .unavailable
            }

            coordinator.refreshNow()
            wait(for: [done], timeout: 5)

            XCTAssertEqual(box.value, false)
        }
    }

    // MARK: - start() / stop()

    @MainActor
    func testStartPrimesImmediateRefresh() {
        // A long interval so no real tick can land during the test; the only scan we expect is
        // the immediate one `start()` primes.
        let counter = Counter()
        let primed = expectation(description: "primed refresh ran")
        let input = StubInput()
        let delegate = RecordingDelegate()

        withExtendedLifetime((input, delegate)) {
            let coordinator = TokenStatsRefreshCoordinator(interval: 300) { _, _ in
                counter.increment()
                primed.fulfill()
                return .unavailable
            }
            coordinator.input = input
            coordinator.delegate = delegate

            coordinator.start()
            wait(for: [primed], timeout: 5)

            XCTAssertEqual(counter.value, 1)
            coordinator.stop()
        }
    }

    @MainActor
    func testStartTwiceDoesNotDoubleTicks() {
        // A short, injected interval instead of waiting out the real 300s cadence.
        let interval: TimeInterval = 0.2
        let counter = Counter()
        let input = StubInput()
        let delegate = RecordingDelegate()

        withExtendedLifetime((input, delegate)) {
            let coordinator = TokenStatsRefreshCoordinator(interval: interval) { _, _ in
                counter.increment()
                return .unavailable
            }
            coordinator.input = input
            coordinator.delegate = delegate

            coordinator.start()
            coordinator.start() // must invalidate the first timer, not run two in parallel

            // Two start() calls contribute exactly two immediate scans (whether both run right
            // away, or the second coalesces into one guaranteed follow-up - either way the
            // total is two, never more, never fewer). If start() left a second timer running
            // alongside the first, this window (1.5x the interval) contains one tick from each
            // of the two timers instead of one tick from a single timer, so the count would
            // exceed 3.
            let settle = expectation(description: "settle past one tick")
            DispatchQueue.main.asyncAfter(deadline: .now() + interval * 1.5) {
                settle.fulfill()
            }
            wait(for: [settle], timeout: 5)

            XCTAssertEqual(
                counter.value, 3,
                "start() called twice must not leave two timers ticking"
            )
            coordinator.stop()
        }
    }

    @MainActor
    func testStopBeforeStartDoesNotCrash() {
        let coordinator = TokenStatsRefreshCoordinator(interval: 300) { _, _ in .unavailable }
        coordinator.stop()
    }
}
