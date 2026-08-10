//
//  TokenStatsRefreshCoordinator.swift
//  Claude Usage
//

import Foundation

/// Supplies the inputs a token-stats refresh needs, read fresh at each refresh so a
/// toggle or card change takes effect on the next tick without re-wiring anything.
///
/// `@MainActor` because the concrete implementation (the active profile's icon config) is
/// main-actor state. The app target infers this automatically for every unannotated type
/// (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), so within that module the annotation is
/// redundant. It is kept because the test target does not set that build setting, so here it is
/// what pins conforming stub types - and the coordinator methods that touch this protocol - to
/// the main actor.
@MainActor
protocol TokenStatsInputProviding: AnyObject {
    var enabledTokenFrames: Set<MenuBarMetricType> { get }
    var countCacheTokens: Bool { get }
}

protocol TokenStatsRefreshCoordinatorDelegate: AnyObject {
    func tokenStatsCoordinator(_ coordinator: TokenStatsRefreshCoordinator, didLoad stats: TokenStats)
}

/// Drives Claude Code token-stat reads on their own slow cadence.
///
/// These stats come from local files, not the network, and they are far more expensive to
/// compute than the API-backed usage percentages: a 30-day window walks every JSONL file
/// touched in that period. Running them on the 30-second usage timer meant re-reading tens of
/// megabytes twice a minute, so they get their own timer at `Constants.RefreshIntervals.tokenStats`.
///
/// The app target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so - like every other
/// unannotated type in the module - this class is implicitly `@MainActor`. The scan itself still
/// runs on a background queue, though, so the pieces that are genuinely touched from that
/// background block are marked `nonisolated` to match how they are actually used: the lock
/// (`stateLock`), the three flags it protects (`_isLoading`, `pendingRefresh`, `generation`), and
/// `finishScan`, which is called directly from the background closure. `start()`, `stop()`, and
/// `refreshNow()` stay on the main actor because they read `input`, which is main-actor state.
/// Within this module the explicit `@MainActor` on those three is redundant (the type is already
/// implicitly main-actor); it is kept because it also constrains the test target, which does not
/// set `SWIFT_DEFAULT_ACTOR_ISOLATION`, so it is what pins those entry points to the main actor
/// there.
final class TokenStatsRefreshCoordinator {

    /// Injected so tests can drive the coordinator without touching `~/.claude`.
    private let load: (Set<MenuBarMetricType>, Bool) -> TokenStats

    /// The timer interval. Defaults to the production cadence; tests inject a short interval
    /// instead of waiting out the real 300 seconds.
    private let interval: TimeInterval

    private var refreshTimer: Timer?
    private let queue = DispatchQueue(label: "com.claudeusage.tokenstats", qos: .utility)
    private nonisolated let stateLock = NSLock()
    // `nonisolated(unsafe)`, not plain `nonisolated`: the latter is rejected for *mutable*
    // stored properties ("'nonisolated' cannot be applied to mutable stored properties"),
    // because the compiler can't verify their access is safe on its own. `stateLock` is what
    // actually provides that safety - every read and write below is one of the paired
    // lock/unlock sections in this file, never a bare access.
    private nonisolated(unsafe) var _isLoading = false

    /// Set when a refresh request arrives while a scan is already in flight. Consumed (and
    /// cleared) exactly once, when that scan finishes, to start exactly one follow-up scan.
    /// Multiple requests arriving during the same in-flight scan collapse into this single flag
    /// rather than each queuing their own follow-up.
    private nonisolated(unsafe) var pendingRefresh = false

    /// Bumped by `stop()`. A scan captures the generation it started under; if that no longer
    /// matches by the time the scan completes, `stop()` ran meanwhile and the result is stale
    /// (e.g. it belongs to a profile that has since been switched away from) and is discarded.
    private nonisolated(unsafe) var generation = 0

    weak var delegate: TokenStatsRefreshCoordinatorDelegate?
    weak var input: TokenStatsInputProviding?

    /// True while a scan is in flight. `nonisolated` because it only ever touches the
    /// lock-protected state above, none of which requires the main actor.
    nonisolated var isLoading: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isLoading
    }

    init(
        interval: TimeInterval = Constants.RefreshIntervals.tokenStats,
        load: @escaping (Set<MenuBarMetricType>, Bool) -> TokenStats = { frames, countCache in
            TokenStatsService().load(enabledFrames: frames, countCacheTokens: countCache)
        }
    ) {
        self.interval = interval
        self.load = load
    }

    deinit {
        // `refreshTimer` is main-actor state, but by the time `deinit` runs there is no
        // concurrent access to race: nothing else holds `self`. The thread `deinit` itself runs
        // on is the real hazard - the background scan closure below strongifies `self` for its
        // duration, so if the owner drops its reference mid-scan, the closure's local `self` can
        // be the last one, and `deinit` then runs on the utility queue, not the main thread.
        // `Timer.invalidate()` must be called on the thread that installed the timer, so capture
        // it into a local (keeping it alive independent of `self`) and hop to the main queue
        // rather than invalidating it here directly.
        let timer = refreshTimer
        DispatchQueue.main.async {
            timer?.invalidate()
        }
    }

    // MARK: - Lifecycle

    @MainActor
    func start() {
        stop()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            // The timer fires on the main run loop, but a plain Timer closure is not itself
            // main-actor isolated as far as the type checker is concerned, and `refreshNow()`
            // is `@MainActor`. Hop explicitly rather than asserting isolation.
            Task { @MainActor [weak self] in
                self?.refreshNow()
            }
        }
        // `.common` so the timer keeps firing while a status-item menu or popover is tracking
        // the run loop in `.eventTracking` mode - `Timer.scheduledTimer` would install into
        // `.default` only and stall for the duration of that tracking. Matches the pattern
        // already used for `Timer` in NotchSessionStore.startStaleSweep().
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        refreshNow()
        LoggingService.shared.logInfo("Token stats refresh coordinator started")
    }

    @MainActor
    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil

        stateLock.lock()
        generation += 1
        // A refresh requested before `stop()` must not resurrect scanning after it: without
        // this, a scan already in flight when `stop()` runs would still see `pendingRefresh` set
        // when it finishes and start a follow-up scan - with no timer running and after the
        // coordinator was told to stop.
        pendingRefresh = false
        stateLock.unlock()
    }

    // MARK: - Refresh

    /// Recomputes token stats now. Callers use this for app start, toggle changes, metric
    /// enable/disable, and user-triggered refreshes - none of which should wait out the
    /// interval.
    ///
    /// If a scan is already in flight, this does not start a second one alongside it (two
    /// concurrent scans could each hold hundreds of MB of mapped JSONL) and it does not drop
    /// the request either: it sets a pending flag, and when the in-flight scan finishes it
    /// starts exactly one follow-up scan that re-reads `input` fresh. Any number of calls
    /// arriving during one in-flight scan collapse into that single follow-up. This matters
    /// because callers use this entry point precisely when inputs just changed (a toggle, a
    /// profile switch) - dropping the call would let a scan that started under the old inputs
    /// deliver stats that no longer match the current settings, for up to a full interval.
    ///
    /// Must be called from the main actor: `input` is main-actor state (the active profile's
    /// icon config), so it is read here, synchronously, before anything is handed to the
    /// background queue. Reading it from inside the async block instead would touch main-actor
    /// state off the main actor.
    @MainActor
    func refreshNow() {
        let frames = input?.enabledTokenFrames ?? []
        let countCache = input?.countCacheTokens ?? true

        stateLock.lock()
        if _isLoading {
            pendingRefresh = true
            stateLock.unlock()
            return
        }
        _isLoading = true
        let scanGeneration = generation
        stateLock.unlock()

        queue.async { [weak self] in
            guard let self else { return }

            let stats = frames.isEmpty ? TokenStats.unavailable : self.load(frames, countCache)

            self.finishScan(generation: scanGeneration, stats: stats)
        }
    }

    /// Runs on the background queue right after a scan completes. Decides whether the result is
    /// still current (see `generation`) and - only if it is, and a refresh coalesced in while
    /// this scan was running - kicks off exactly one follow-up on the main actor. A stale result
    /// never triggers a follow-up of its own: `stop()` already cleared `pendingRefresh`, and
    /// gating on staleness here as well means a scan that finishes *between* `stop()`'s two
    /// critical sections (bumping `generation`, then clearing `pendingRefresh`) still can't
    /// resurrect scanning. `_isLoading` is cleared on the main actor below, right before this
    /// method's caller would otherwise be free to start a genuinely-redundant concurrent scan;
    /// see the note on that line for why it isn't cleared here instead.
    private nonisolated func finishScan(generation scanGeneration: Int, stats: TokenStats) {
        stateLock.lock()
        let isStale = scanGeneration != generation
        let shouldRefreshAgain = !isStale && pendingRefresh
        pendingRefresh = false
        stateLock.unlock()

        Task { @MainActor [weak self] in
            guard let self else { return }
            if !isStale {
                self.delegate?.tokenStatsCoordinator(self, didLoad: stats)
            }
            // Cleared here, after delivery, rather than back in the background block above:
            // clearing it there would open a window - between this scan finishing and its
            // result reaching the delegate on the main actor - where an external `refreshNow()`
            // sees the coordinator as idle and starts a second, genuinely redundant scan
            // alongside the follow-up already queued via `pendingRefresh`. Keeping `_isLoading`
            // true across that hop closes the window entirely.
            self.clearIsLoadingAfterDelivery()
            if shouldRefreshAgain {
                self.refreshNow()
            }
        }
    }

    /// `NSLock.lock()`/`unlock()` are marked unavailable from asynchronous contexts (calling them
    /// directly inside an `async` closure is a priority-inversion risk the compiler now flags).
    /// This wraps the pair in an ordinary synchronous, `nonisolated` function so `finishScan`'s
    /// `Task { @MainActor in ... }` continuation above can call it without tripping that
    /// diagnostic - calling a synchronous function from an async context is unrestricted; only
    /// the direct lock/unlock call sites are.
    private nonisolated func clearIsLoadingAfterDelivery() {
        stateLock.lock()
        _isLoading = false
        stateLock.unlock()
    }
}
