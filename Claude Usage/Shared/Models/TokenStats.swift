import Foundation

/// Aggregated Claude Code CLI token totals. By default this counts all four token kinds (input,
/// output, cache read, cache creation) to match what `claude` itself reports; a "Count cache
/// tokens" toggle switches individual frames to input + output only.
///
/// `nonisolated`: a plain value type with no shared mutable state, safe to touch from any
/// isolation domain. `TokenStatsService.load` (itself `nonisolated` so it can run its JSONL scan
/// off the main actor) returns `.unavailable` from within helpers that run on a background
/// queue, which is a cross-isolation-domain reference to this type's static property unless it
/// is nonisolated too.
nonisolated struct TokenStats: Codable, Equatable {
    let allTime: Int
    let last7Days: Int
    let last30Days: Int
    /// False when nothing backing the enabled frames could be read. Judged per enabled frame's
    /// own source, not just "is the cache present": in cache-exclusive mode the cache backs
    /// all-time but not the window frames, so a readable cache alone is not enough once a window
    /// frame is enabled - that also requires JSONL to have parsed at least one day. See
    /// `TokenStatsService.loadCacheExclusive` for the full breakdown.
    let isAvailable: Bool

    static let unavailable = TokenStats(allTime: 0, last7Days: 0, last30Days: 0, isAvailable: false)

    /// Token count for a token metric type, or nil for non-token metrics.
    func value(for metricType: MenuBarMetricType) -> Int? {
        switch metricType {
        case .tokensAllTime: return allTime
        case .tokens7Days: return last7Days
        case .tokens30Days: return last30Days
        case .session, .week, .api: return nil
        }
    }
}
