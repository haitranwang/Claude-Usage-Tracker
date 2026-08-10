//
//  TokenStatsRefreshCoordinator.swift
//  Claude Usage
//

import Foundation

/// Supplies the inputs a token-stats refresh needs, read fresh at each refresh so a
/// toggle or card change takes effect on the next tick without re-wiring anything.
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
final class TokenStatsRefreshCoordinator {

    /// Injected so tests can drive the coordinator without touching `~/.claude`.
    private let load: (Set<MenuBarMetricType>, Bool) -> TokenStats

    private var refreshTimer: Timer?
    private let queue = DispatchQueue(label: "com.claudeusage.tokenstats", qos: .utility)
    private let stateLock = NSLock()
    private var _isLoading = false

    weak var delegate: TokenStatsRefreshCoordinatorDelegate?
    weak var input: TokenStatsInputProviding?

    /// True while a scan is in flight. Ticks arriving during one are dropped.
    var isLoading: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isLoading
    }

    init(load: @escaping (Set<MenuBarMetricType>, Bool) -> TokenStats = { frames, countCache in
        TokenStatsService().load(enabledFrames: frames, countCacheTokens: countCache)
    }) {
        self.load = load
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - Lifecycle

    func start() {
        stop()
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: Constants.RefreshIntervals.tokenStats,
            repeats: true
        ) { [weak self] _ in
            self?.refreshNow()
        }
        refreshNow()
        LoggingService.shared.logInfo("Token stats refresh coordinator started")
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Refresh

    /// Recomputes immediately unless a scan is already running, in which case this call is
    /// dropped. Callers use this for app start, toggle changes, metric enable/disable, and
    /// user-triggered refreshes - none of which should wait out the interval.
    ///
    /// Must be called from the main thread: `input` is main-actor state (the active profile's
    /// icon config), so it is read here, synchronously, before anything is handed to the
    /// background queue. Reading it from inside the async block instead would touch main-actor
    /// state off the main actor.
    func refreshNow() {
        let frames = input?.enabledTokenFrames ?? []
        let countCache = input?.countCacheTokens ?? true

        stateLock.lock()
        if _isLoading {
            stateLock.unlock()
            return
        }
        _isLoading = true
        stateLock.unlock()

        queue.async { [weak self] in
            guard let self else { return }

            let stats = frames.isEmpty ? TokenStats.unavailable : self.load(frames, countCache)

            self.stateLock.lock()
            self._isLoading = false
            self.stateLock.unlock()

            DispatchQueue.main.async {
                self.delegate?.tokenStatsCoordinator(self, didLoad: stats)
            }
        }
    }
}
