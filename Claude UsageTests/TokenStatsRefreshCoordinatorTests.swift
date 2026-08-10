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

/// Records values in call order, so a test can assert what a *later* invocation observed - e.g.
/// that a coalesced follow-up scan read `input` fresh rather than reusing what an earlier,
/// already-in-flight scan captured.
private final class CallRecorder {
    private let lock = NSLock()
    private var values: [Bool] = []

    func record(_ value: Bool) {
        lock.lock(); values.append(value); lock.unlock()
    }

    var recorded: [Bool] {
        lock.lock(); defer { lock.unlock() }; return values
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
        let input = StubInput()
        let coordinator = makeCoordinator(input: input, delegate: delegate) { _, _ in
            TokenStats(allTime: 42, last7Days: 7, last30Days: 30, isAvailable: true)
        }

        // `coordinator.input`/`delegate` are weak (matches production, where the owner holds the
        // strong reference); the coordinator itself is only weakly captured by its own async
        // continuations (`queue.async { [weak self] ... }`, `Task { @MainActor [weak self] ... }`).
        // `withExtendedLifetime` keeps all three alive for the whole test rather than only until
        // their last textual use, which under optimisation is not guaranteed to be the end of
        // the scope - without it, ARC is free to release `coordinator` right after `refreshNow()`
        // is called, and the async delivery this test waits for would never happen.
        withExtendedLifetime((input, delegate, coordinator)) {
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
        let coordinator = makeCoordinator(input: input, delegate: delegate) { _, _ in
            let callNumber = counter.incrementAndGet()
            if callNumber == 1 {
                firstStarted.fulfill()
                release.wait()
            }
            return .unavailable
        }

        withExtendedLifetime((input, delegate, coordinator)) {
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
    func testCoalescedFollowUpReReadsChangedInputs() {
        // The whole point of coalescing (rather than dropping or queuing) is that the follow-up
        // scan reads `input` fresh. Nothing above proves that: it only proves a follow-up scan
        // *runs*. Change an input while the first scan is parked and confirm the follow-up
        // observes the new value, not the one the first scan captured.
        let firstStarted = expectation(description: "first scan started")
        let release = DispatchSemaphore(value: 0)
        let bothDelivered = expectation(description: "first scan and its follow-up delivered")
        bothDelivered.expectedFulfillmentCount = 2
        let delegate = RecordingDelegate(expectation: bothDelivered)
        let recorder = CallRecorder()
        let input = StubInput()
        input.countCacheTokens = true
        let coordinator = makeCoordinator(input: input, delegate: delegate) { _, countCache in
            recorder.record(countCache)
            if recorder.recorded.count == 1 {
                firstStarted.fulfill()
                release.wait()
            }
            return .unavailable
        }

        withExtendedLifetime((input, delegate, coordinator)) {
            coordinator.refreshNow()
            wait(for: [firstStarted], timeout: 5)

            // Flip the input while the first scan is parked, then coalesce a follow-up behind it.
            input.countCacheTokens = false
            coordinator.refreshNow()

            release.signal()
            wait(for: [bothDelivered], timeout: 5)

            XCTAssertEqual(
                recorder.recorded, [true, false],
                "the follow-up scan must read input as it is when it starts, not as it was when the in-flight scan began"
            )
        }
    }

    @MainActor
    func testRefreshAfterCompletionRunsAgain() {
        // Sequential (non-overlapping) refreshes must not wedge the coordinator.
        let first = expectation(description: "first")
        let delegate = RecordingDelegate(expectation: first)
        let counter = Counter()
        let input = StubInput()
        let coordinator = makeCoordinator(input: input, delegate: delegate) { _, _ in
            counter.increment()
            return .unavailable
        }

        withExtendedLifetime((input, delegate, coordinator)) {
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
        let coordinator = makeCoordinator(input: input, delegate: delegate) { _, _ in
            counter.increment()
            return .unavailable
        }

        withExtendedLifetime((input, delegate, coordinator)) {
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
        let coordinator = makeCoordinator(input: input, delegate: delegate) { _, countCache in
            box.set(countCache)
            return .unavailable
        }

        withExtendedLifetime((input, delegate, coordinator)) {
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
        let coordinator = TokenStatsRefreshCoordinator(interval: 300) { _, _ in
            counter.increment()
            primed.fulfill()
            return .unavailable
        }
        coordinator.input = input
        coordinator.delegate = delegate

        withExtendedLifetime((input, delegate, coordinator)) {
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

        // Two start() calls contribute exactly two immediate scans (one per call), plus exactly
        // one tick once the interval elapses if start() correctly leaves only one timer running.
        // Rather than sampling the counter at one arbitrary point in time - which either requires
        // the tick to land inside an unrealistically tight window (flaky on a loaded machine) or
        // lets a second timer's coalesced tick land *after* the sample and pass anyway - use an
        // expectation with a hard fulfillment ceiling: a fourth load (from a second, un-invalidated
        // timer) over-fulfills and fails the test immediately, whenever it happens to occur.
        let loadCount = expectation(description: "two immediate scans plus one tick from a single timer")
        loadCount.expectedFulfillmentCount = 3
        loadCount.assertForOverFulfill = true

        let coordinator = TokenStatsRefreshCoordinator(interval: interval) { _, _ in
            counter.increment()
            loadCount.fulfill()
            return .unavailable
        }
        coordinator.input = input
        coordinator.delegate = delegate

        withExtendedLifetime((input, delegate, coordinator)) {
            coordinator.start()
            coordinator.start() // must invalidate the first timer, not run two in parallel

            wait(for: [loadCount], timeout: 5)

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

    // MARK: - stop() fencing

    @MainActor
    func testPendingRefreshDoesNotSurviveStop() {
        // Regression test: a refreshNow() that coalesces while a scan is in flight must not
        // resurrect scanning once stop() has ended the coordinator's lifecycle.
        //
        // Sequence: start a scan (generation 0), park it; call refreshNow() so it sets the
        // pending flag; call stop() (bumps to generation 1); release the parked scan. Before the
        // fix, finishScan still saw the pending flag and started a follow-up scan with no timer
        // running, delivering stats to the delegate after the coordinator was stopped.
        let firstStarted = expectation(description: "first scan started")
        let release = DispatchSemaphore(value: 0)
        let counter = Counter()
        let input = StubInput()
        let delegate = RecordingDelegate()
        // No delivery, and no second load, are expected. Inverted expectations catch either one
        // regardless of when it lands, rather than sampling state once after a fixed delay.
        let noDelivery = expectation(description: "no delivery after stop()")
        noDelivery.isInverted = true
        delegate.expectation = noDelivery

        let coordinator = makeCoordinator(input: input, delegate: delegate) { _, _ in
            let callNumber = counter.incrementAndGet()
            if callNumber == 1 {
                firstStarted.fulfill()
                release.wait()
            }
            return .unavailable
        }

        withExtendedLifetime((input, delegate, coordinator)) {
            coordinator.refreshNow() // scan at generation 0, parks in the loader
            wait(for: [firstStarted], timeout: 5)

            coordinator.refreshNow() // sets pendingRefresh while the scan is in flight
            coordinator.stop()       // bumps to generation 1; must also clear pendingRefresh

            release.signal()        // let the parked scan finish

            wait(for: [noDelivery], timeout: 1)

            XCTAssertEqual(
                counter.value, 1,
                "stop() must prevent the coalesced follow-up scan from ever running"
            )
            XCTAssertTrue(delegate.received.isEmpty, "no stats may reach the delegate once stopped")
        }
    }

    @MainActor
    func testStopDiscardsResultFromScanStartedBeforeIt() {
        // Coverage gap: nothing previously proved the generation fence actually discards a
        // pre-stop() result end-to-end (as opposed to just tracking staleness internally). Park
        // a scan, stop() before it finishes, release it, and confirm the delegate gets nothing -
        // with no pending refresh involved this time, isolating the fence itself.
        let started = expectation(description: "scan started")
        let release = DispatchSemaphore(value: 0)
        let input = StubInput()
        let delegate = RecordingDelegate()
        let noDelivery = expectation(description: "no delivery of the stale result")
        noDelivery.isInverted = true
        delegate.expectation = noDelivery

        let coordinator = makeCoordinator(input: input, delegate: delegate) { _, _ in
            started.fulfill()
            release.wait()
            return TokenStats(allTime: 99, last7Days: 9, last30Days: 90, isAvailable: true)
        }

        withExtendedLifetime((input, delegate, coordinator)) {
            coordinator.refreshNow()
            wait(for: [started], timeout: 5)

            coordinator.stop()
            release.signal()

            wait(for: [noDelivery], timeout: 1)

            XCTAssertTrue(
                delegate.received.isEmpty,
                "a result from a scan that started before stop() must be discarded, not delivered"
            )
        }
    }
}
