//
//  TokenStatsRefreshCoordinator.swift
//  Claude Usage
//

import Foundation

/// Supplies the inputs a token-stats refresh needs, read fresh at each refresh so a
/// toggle or card change takes effect on the next tick without re-wiring anything.
///
/// `@MainActor` because the concrete implementation (the active profile's icon config) is
/// main-actor state. Coordinator methods that touch this protocol are themselves `@MainActor`
/// so the compiler enforces the contract instead of it being a comment.
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
/// The class itself is *not* `@MainActor`: the scan runs on a background queue, and the
/// lock-protected flags below (`_isLoading`, `pendingRefresh`, `generation`) are read and
/// written from that background block. Only the entry points that touch `input` (main-actor
/// state) are annotated `@MainActor`.
final class TokenStatsRefreshCoordinator {

    /// Injected so tests can drive the coordinator without touching `~/.claude`.
    private let load: (Set<MenuBarMetricType>, Bool) -> TokenStats

    /// The timer interval. Defaults to the production cadence; tests inject a short interval
    /// instead of waiting out the real 300 seconds.
    private let interval: TimeInterval

    private var refreshTimer: Timer?
    private let queue = DispatchQueue(label: "com.claudeusage.tokenstats", qos: .utility)
    private let stateLock = NSLock()
    private var _isLoading = false

    /// Set when a refresh request arrives while a scan is already in flight. Consumed (and
    /// cleared) exactly once, when that scan finishes, to start exactly one follow-up scan.
    /// Multiple requests arriving during the same in-flight scan collapse into this single flag
    /// rather than each queuing their own follow-up.
    private var pendingRefresh = false

    /// Bumped by `stop()`. A scan captures the generation it started under; if that no longer
    /// matches by the time the scan completes, `stop()` ran meanwhile and the result is stale
    /// (e.g. it belongs to a profile that has since been switched away from) and is discarded.
    private var generation = 0

    weak var delegate: TokenStatsRefreshCoordinatorDelegate?
    weak var input: TokenStatsInputProviding?

    /// True while a scan is in flight.
    var isLoading: Bool {
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
        refreshTimer?.invalidate()
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

    /// Runs on the background queue right after a scan completes. Clears the in-flight flag,
    /// decides whether the result is still current (see `generation`), and - if a refresh
    /// coalesced in while this scan was running - kicks off exactly one follow-up on the main
    /// actor. Discarding a stale result still clears `isLoading` and still honours a pending
    /// refresh, so a superseded scan can never wedge the coordinator.
    private func finishScan(generation scanGeneration: Int, stats: TokenStats) {
        stateLock.lock()
        _isLoading = false
        let isStale = scanGeneration != generation
        let shouldRefreshAgain = pendingRefresh
        pendingRefresh = false
        stateLock.unlock()

        Task { @MainActor [weak self] in
            guard let self else { return }
            if !isStale {
                self.delegate?.tokenStatsCoordinator(self, didLoad: stats)
            }
            if shouldRefreshAgain {
                self.refreshNow()
            }
        }
    }
}
