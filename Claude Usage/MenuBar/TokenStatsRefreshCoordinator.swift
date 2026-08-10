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
/// (`stateLock`), the three flags it protects (`_isLoading`, `pendingRefresh`, `generation`),
/// `finishScan` (called directly from the background closure), and `completeScan` (called from
/// `finishScan`'s main-actor continuation). `start()`, `stop()`, and `refreshNow()` stay on the
/// main actor because they read `input`, which is main-actor state. Within this module the
/// explicit `@MainActor` on those three is redundant (the type is already implicitly
/// main-actor); it is kept because it also constrains the test target, which does not set
/// `SWIFT_DEFAULT_ACTOR_ISOLATION`, so it is what pins those entry points to the main actor
/// there.
final class TokenStatsRefreshCoordinator {

    /// Injected so tests can drive the coordinator without touching `~/.claude`.
    ///
    /// `nonisolated`, not implicitly main-actor: this is read from `refreshNow()`'s `@Sendable`
    /// background closure (`queue.async`), and a plain stored `let` of a non-Sendable function
    /// type on an (implicitly) main-actor class cannot be read from off the main actor - the
    /// value itself doesn't change after `init`, but the type checker can't see that without the
    /// type being provably safe to share. Marking the closure type `@Sendable` makes it so, and
    /// `nonisolated` is legal here (unlike on `_isLoading` et al. below) specifically because this
    /// is a `let`: immutable stored properties of `Sendable` type may be accessed from any
    /// isolation domain.
    private nonisolated let load: @Sendable (Set<MenuBarMetricType>, Bool) -> TokenStats

    /// The timer interval. Defaults to the production cadence; tests inject a short interval
    /// instead of waiting out the real 300 seconds.
    private let interval: TimeInterval

    // `nonisolated(unsafe)`, not plain `nonisolated`: this is a `var`, and (per the note on
    // `_isLoading` below) `nonisolated` is only accepted on immutable stored properties. `Timer`
    // is also not `Sendable`, so a plain main-actor-isolated `var` here could not be read from
    // `deinit`, which runs `nonisolated` (see `deinit` below for why that read is unavoidable).
    // Safety still holds: every access from `start()`/`stop()` is on the main actor, matching how
    // this property is actually used everywhere except the teardown case `deinit` documents.
    private nonisolated(unsafe) var refreshTimer: Timer?
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
        load: @escaping @Sendable (Set<MenuBarMetricType>, Bool) -> TokenStats = { frames, countCache in
            TokenStatsService().load(enabledFrames: frames, countCacheTokens: countCache)
        }
    ) {
        self.interval = interval
        self.load = load
    }

    deinit {
        // By the time `deinit` runs there is no concurrent access to `refreshTimer` to race:
        // nothing else holds `self`. The thread `deinit` itself runs on is the real hazard - the
        // background scan closure below strongifies `self` for its duration, so if the owner
        // drops its reference mid-scan, the closure's local `self` can be the last one, and
        // `deinit` then runs on the utility queue, not the main thread. `Timer.invalidate()` must
        // be called on the thread that installed the timer, so capture it into a local (keeping
        // it alive independent of `self`) and hop to the main queue rather than invalidating it
        // here directly.
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

    /// Runs on the background queue right after a scan completes. The decision of what to do
    /// about it - deliver the result, start a follow-up, clear the in-flight flag - is
    /// deliberately *not* made here: it is made in `completeScan`, inside the `@MainActor`
    /// continuation below, so that it is ordered after anything that ran on the main actor while
    /// the scan was in flight (most importantly `stop()`). Deciding here instead, on the
    /// background queue, would let a `stop()` (or a `refreshNow()`) that runs during the hop to
    /// the main actor go unaccounted for - see `completeScan`'s doc comment for the specific
    /// failure modes that produced.
    private nonisolated func finishScan(generation scanGeneration: Int, stats: TokenStats) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let (deliver, again) = self.completeScan(generation: scanGeneration)
            if deliver {
                self.delegate?.tokenStatsCoordinator(self, didLoad: stats)
            }
            if again {
                self.refreshNow()
            }
        }
    }

    /// The single locked section that decides a finished scan's fate: whether its result is
    /// still current enough to deliver, whether a follow-up scan is owed, and clearing
    /// `_isLoading` - all three, together, so nothing can run on the main actor between them.
    ///
    /// This runs *after* the hop to the main actor in `finishScan` above (not on the background
    /// queue where the scan itself ran) specifically so it is ordered after a `stop()` that ran
    /// while the scan was in flight:
    ///
    /// - `deliver` reads `generation` here, after the hop, so a `stop()` that bumped it before
    ///   this section runs is honored even though it happened after the scan itself finished.
    /// - `again` reads `pendingRefresh` here, after the hop, so a `stop()` that already cleared
    ///   it fences a request set before `stop()` ran, while a `refreshNow()` that sets it *after*
    ///   `stop()` (and before this section runs) still survives - that request came from the main
    ///   actor after `stop()` had its say, so it is not one `stop()` was meant to cancel. It is
    ///   deliberately not additionally gated on `deliver`: a follow-up scan re-reads `input` from
    ///   scratch, so it is correct regardless of whether the scan that triggered it was stale.
    /// - `_isLoading` is cleared in this same section, not back in the background block, so there
    ///   is no window - between a scan finishing and this decision running - where an external
    ///   `refreshNow()` sees the coordinator as idle and starts a second, genuinely redundant scan
    ///   alongside a follow-up already implied by `pendingRefresh`.
    ///
    /// Marked `nonisolated` rather than `@MainActor`, even though its only caller is a
    /// `@MainActor` continuation, because `NSLock.lock()`/`unlock()` are unavailable from
    /// asynchronous contexts (calling them directly inside an `async` function is a
    /// priority-inversion risk the compiler flags) - wrapping the pair in an ordinary synchronous,
    /// `nonisolated` function sidesteps that: calling a synchronous function from an async context
    /// is unrestricted, only the direct lock/unlock call sites are.
    private nonisolated func completeScan(generation scanGeneration: Int) -> (deliver: Bool, again: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let deliver = scanGeneration == generation
        let again = pendingRefresh
        pendingRefresh = false
        _isLoading = false
        return (deliver, again)
    }
}
