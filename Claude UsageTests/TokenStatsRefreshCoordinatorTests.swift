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
///
/// `@unchecked Sendable`: every stored property is private and every access - read or write -
/// goes through `lock`, so it is genuinely safe to share across the isolation domains this test
/// file hands it to (the coordinator's background queue, its `@MainActor` delivery, and the test
/// method itself). The compiler cannot verify that on its own for a plain reference type with
/// mutable state, which is exactly what this annotation is for.
private final class Counter: @unchecked Sendable {
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

        // The two start() calls do NOT contribute two immediate scans of their own: `queue.async`
        // can never run inline on the calling thread, so by the time the second start()'s
        // internal refreshNow() runs (synchronously, right after the first), the first call's
        // scan has not yet had a chance to finish - isLoading is still true, so the second call's
        // refresh always coalesces via pendingRefresh rather than launching a second scan
        // alongside it. What actually happens, deterministically, is: one immediate scan from the
        // first start() (which the second start()'s stop() then makes stale by bumping the
        // generation), one follow-up scan once that stale scan finishes (consuming the coalesced
        // pendingRefresh, now under the fresh generation), and - if start() correctly leaves only
        // one timer running - exactly one tick once the interval elapses. Three loads total.
        //
        // Rather than asserting that exact sequence directly, use an expectation with a hard
        // fulfillment ceiling: a fourth load (which only a second, un-invalidated timer ticking
        // in parallel could produce) over-fulfills and fails the test immediately, whenever it
        // happens to occur. This is what actually distinguishes "one timer" from "two timers" -
        // the count of loads contributed by the two start() calls themselves is 2 either way.
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

    @MainActor
    func testStartWhileScanInFlightStillProducesFreshDelivery() {
        // Defect 1 regression: start() calls stop() internally, which bumps the generation and
        // clears pendingRefresh. If a scan is already in flight when start() runs, its own
        // primed refreshNow() call finds isLoading still true and coalesces via pendingRefresh
        // rather than dropping straight through - so that pending flag must survive the stop()
        // that already ran, and the in-flight scan's completion must turn it into a genuinely
        // fresh follow-up scan (reading input fresh, under the new generation), not silently do
        // nothing until the next timer tick. Before the fix, the `!isStale &&` gate in
        // finishScan discarded this pending flag along with the stale scan, and the coordinator
        // would sit idle with no data until the next tick.
        let scanAStarted = expectation(description: "scan A started")
        let release = DispatchSemaphore(value: 0)
        let delivered = expectation(description: "the fresh scan start() primed was delivered")
        let delegate = RecordingDelegate(expectation: delivered)
        let counter = Counter()
        let input = StubInput()

        let coordinator = TokenStatsRefreshCoordinator(interval: 300) { _, _ in
            let callNumber = counter.incrementAndGet()
            if callNumber == 1 {
                scanAStarted.fulfill()
                release.wait()
                // Scan A's own result; it must never reach the delegate; it belongs to the
                // generation stop() (via start()) already invalidated.
                return TokenStats(allTime: 1, last7Days: 1, last30Days: 1, isAvailable: true)
            }
            return TokenStats(allTime: 2, last7Days: 2, last30Days: 2, isAvailable: true)
        }
        coordinator.input = input
        coordinator.delegate = delegate

        withExtendedLifetime((input, delegate, coordinator)) {
            coordinator.refreshNow() // scan A begins, parks in the loader
            wait(for: [scanAStarted], timeout: 5)

            // start() calls stop() (bumping the generation and clearing pendingRefresh) and then
            // primes a refresh of its own - which coalesces, since scan A is still in flight.
            coordinator.start()

            release.signal() // let scan A finish; its result is now stale

            wait(for: [delivered], timeout: 5)

            XCTAssertEqual(
                counter.value, 2,
                "start() while a scan is in flight must trigger exactly one fresh follow-up scan"
            )
            XCTAssertEqual(delegate.received.count, 1, "only the fresh scan's result may reach the delegate")
            XCTAssertEqual(
                delegate.received.first?.allTime, 2,
                "the delivered result must be the fresh scan's, not the stale one from before start()"
            )

            coordinator.stop()
        }
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

    @MainActor
    func testStopRacingScanCompletionSuppressesDelivery() {
        // Defect 3 regression: the previous fix latched staleness on the background queue, right
        // as the scan finished, before hopping to the main actor to deliver. A stop() that runs
        // after that latch but before the delivery continuation executes still saw the pre-stop()
        // "not stale" verdict and delivered anyway - and could still authorise a follow-up scan.
        // The fix moves the whole decision (staleness, delivery, follow-up) into a single locked
        // section inside the main-actor continuation, so it is ordered after any stop() that has
        // already run by the time that continuation gets to execute - not after whatever the
        // background queue happened to observe first.
        //
        // The loader signals a semaphore on its way out (its work is done; it is about to return
        // control to the coordinator's background block), and this test blocks the main actor on
        // that semaphore. The signalling background thread runs on into the coordinator's
        // completion handling with no context switch of its own, while the waiting main thread
        // must first be woken by the scheduler - so by the time this test's stop() call runs, the
        // background side has, in practice, already finished its part of the race. Blocking the
        // main actor for the duration additionally guarantees the delivery continuation itself
        // cannot execute until after stop() returns, regardless of how that race lands, which is
        // what makes the assertions below hold deterministically post-fix.
        let loaderAboutToReturn = DispatchSemaphore(value: 0)
        let input = StubInput()
        let delegate = RecordingDelegate()
        let noDelivery = expectation(description: "no delivery of a result racing stop() on its way out")
        noDelivery.isInverted = true
        delegate.expectation = noDelivery
        let counter = Counter()

        let coordinator = makeCoordinator(input: input, delegate: delegate) { _, _ in
            counter.increment()
            let stats = TokenStats(allTime: 5, last7Days: 5, last30Days: 5, isAvailable: true)
            loaderAboutToReturn.signal()
            return stats
        }

        withExtendedLifetime((input, delegate, coordinator)) {
            coordinator.refreshNow()
            loaderAboutToReturn.wait()

            coordinator.stop()

            wait(for: [noDelivery], timeout: 1)

            XCTAssertEqual(
                counter.value, 1,
                "stop() must not authorise a follow-up scan for a result it raced"
            )
            XCTAssertTrue(
                delegate.received.isEmpty,
                "a result racing stop() on its way out must still be discarded, not delivered"
            )
        }
    }
}
