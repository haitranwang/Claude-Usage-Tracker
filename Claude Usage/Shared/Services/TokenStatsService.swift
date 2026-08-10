import Foundation

/// Reads and aggregates Claude Code CLI token usage to match what `claude`'s live "Stats" view
/// reports: input + output + cache-read + cache-creation tokens.
///
/// Including cache tokens is what the CLI does, not an editorial choice. CLI 2.1.221 changed
/// `stats-cache.json`'s `dailyModelTokens` from `input + output` to all four kinds, and added a
/// `dailyModelTokensVersion` field whose bump makes the CLI rebuild that history under the new
/// definition. Since `dailyModelTokens` is the only per-day source available, the 7D/30D windows
/// are cache-inclusive whether we like it or not - so the all-time aggregate and the JSONL delta
/// must count the same four kinds, or the frames would report different quantities and a 7-day
/// window could exceed all-time. Cache reads dominate the total (often >90%); this is a volume
/// figure, not a proxy for cost, since cache reads bill at a fraction of input tokens.
///
/// `~/.claude/stats-cache.json` is only refreshed periodically by the CLI, so reading it alone
/// lags behind the live number by however many days have passed since its `lastComputedDate`.
/// The CLI's live total is effectively:
///
///     cache totals (authoritative through lastComputedDate)
///   + input/output tokens from the raw JSONL session logs for days AFTER lastComputedDate
///
/// This service reproduces that by treating `lastComputedDate` as a cutoff: days on/before it
/// are read from the cache (cheap), and only days after it are recomputed from
/// `~/.claude/projects/**/*.jsonl` (comparatively expensive). To bound that JSONL work, only the
/// time frames present in `enabledFrames` are scanned for; the rest are left at 0.
struct TokenStatsService {

    /// Which token kinds a total counts.
    ///
    /// `.all` is what `claude` reports and what `dailyModelTokens` stores since CLI 2.1.221.
    /// `.inputOutputOnly` is the pre-2.1.221 meaning, kept available because cache reads are
    /// ~95% of `.all` and bill at a fraction of input tokens.
    enum TokenKind {
        case all
        case inputOutputOnly
    }

    // MARK: - stats-cache.json decoding

    private struct Cache: Decodable {
        struct Model: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            let cacheReadInputTokens: Int?
            let cacheCreationInputTokens: Int?

            func amount(counting kind: TokenKind) -> Int {
                let io = (inputTokens ?? 0) + (outputTokens ?? 0)
                switch kind {
                case .inputOutputOnly: return io
                case .all: return io + (cacheReadInputTokens ?? 0) + (cacheCreationInputTokens ?? 0)
                }
            }
        }
        struct Daily: Decodable {
            let date: String
            let tokensByModel: [String: Int]
        }
        let modelUsage: [String: Model]?
        let dailyModelTokens: [Daily]?
        /// "yyyy-MM-dd" - the day through which the cache's totals are authoritative.
        let lastComputedDate: String?
    }

    // MARK: - JSONL line decoding

    /// Minimal shape of one assistant line in a `~/.claude/projects/**/*.jsonl` session file.
    ///
    /// Keys are spelled out rather than derived via `.convertFromSnakeCase`: that strategy
    /// transforms every key of every decoded object, including the many this struct ignores
    /// (`content`, `id`, `role`, `model`, `stop_reason`, ...). Profiling put it at 11% of scan
    /// time for six fields' worth of benefit.
    private struct Line: Decodable {
        struct Message: Decodable {
            struct Usage: Decodable {
                let inputTokens: Int?
                let outputTokens: Int?
                let cacheReadInputTokens: Int?
                let cacheCreationInputTokens: Int?

                enum CodingKeys: String, CodingKey {
                    case inputTokens = "input_tokens"
                    case outputTokens = "output_tokens"
                    case cacheReadInputTokens = "cache_read_input_tokens"
                    case cacheCreationInputTokens = "cache_creation_input_tokens"
                }

                func amount(counting kind: TokenKind) -> Int {
                    let io = (inputTokens ?? 0) + (outputTokens ?? 0)
                    switch kind {
                    case .inputOutputOnly: return io
                    case .all: return io + (cacheReadInputTokens ?? 0) + (cacheCreationInputTokens ?? 0)
                    }
                }
            }
            let usage: Usage?
        }
        let message: Message?
        let timestamp: String?
    }

    // MARK: - Calendar / date-key helpers

    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func startOfDay(_ date: Date) -> Date {
        Self.calendar.startOfDay(for: date)
    }

    private func dayKey(_ date: Date) -> String {
        Self.dayFormatter.string(from: date)
    }

    private func dayAfter(_ date: Date) -> Date {
        Self.calendar.date(byAdding: .day, value: 1, to: date) ?? date
    }

    // MARK: - Public API

    /// Loads token stats for exactly the requested frames.
    ///
    /// - Parameters:
    ///   - enabledFrames: Menu-bar metrics currently enabled. Non-token metrics are ignored.
    ///     Frames not present here are left at 0 - this is the load-reduction that keeps the
    ///     JSONL scan bounded to only what's actually displayed.
    /// - Returns: `.unavailable` when neither the cache nor any JSONL file could be read, or
    ///   when no token frame is enabled.
    func load(
        enabledFrames: Set<MenuBarMetricType>,
        statsURL: URL = Constants.ClaudePaths.statsCacheFile,
        projectsDir: URL = Constants.ClaudePaths.projectsDirectory,
        referenceDate: Date = Date()
    ) -> TokenStats {
        let tokenFrames = enabledFrames.filter { $0.isTokenMetric }
        guard !tokenFrames.isEmpty else { return .unavailable }

        let (cacheAllTime, cacheDaily, lastComputed, cacheAvailable) = readCache(from: statsURL, counting: .all)
        let today = startOfDay(referenceDate)

        // Days on/before this are authoritative in the cache; days after it need JSONL.
        // With no usable cache, .distantPast means "nothing is covered - everything from JSONL".
        let cacheCutoff = lastComputed ?? .distantPast

        // Lower bound for the JSONL scan: the earliest day any enabled frame still needs.
        // All-time needs every day after the cutoff (the widest possible need), which also
        // covers any window frame enabled alongside it.
        let scanFrom: Date
        if tokenFrames.contains(.tokensAllTime) {
            scanFrom = dayAfter(cacheCutoff)
        } else {
            let maxWindow = tokenFrames.contains(.tokens30Days) ? 30 : 7
            let windowStart = Self.calendar.date(byAdding: .day, value: -(maxWindow - 1), to: today) ?? today
            scanFrom = max(dayAfter(cacheCutoff), windowStart)
        }

        // A cutoff on or after today makes `dayAfter(cutoff) > today`, which would trap when
        // constructing the range. That happens routinely — the CLI advances lastComputedDate to
        // today whenever it recomputes — and means the cache already covers everything.
        let (deltaDaily, anyJSONLParsed): ([String: Int], Bool) = scanFrom <= today
            ? scanJSONL(projectsDir: projectsDir, range: scanFrom...today, counting: .all)
            : ([:], false)

        var allTime = 0
        var last7Days = 0
        var last30Days = 0

        if tokenFrames.contains(.tokensAllTime) {
            // deltaDaily only holds days > cacheCutoff (scanFrom = dayAfter(cutoff) above), so
            // its full sum is exactly the "days after the cache" contribution.
            allTime = cacheAllTime + deltaDaily.values.reduce(0, +)
        }
        if tokenFrames.contains(.tokens7Days) {
            last7Days = windowSum(days: 7, today: today, cacheCutoff: cacheCutoff, cacheDaily: cacheDaily, deltaDaily: deltaDaily)
        }
        if tokenFrames.contains(.tokens30Days) {
            last30Days = windowSum(days: 30, today: today, cacheCutoff: cacheCutoff, cacheDaily: cacheDaily, deltaDaily: deltaDaily)
        }

        guard cacheAvailable || anyJSONLParsed else { return .unavailable }

        return TokenStats(allTime: allTime, last7Days: last7Days, last30Days: last30Days, isAvailable: true)
    }

    // MARK: - Cache reading

    private func readCache(
        from url: URL,
        counting kind: TokenKind
    ) -> (allTime: Int, daily: [String: Int], lastComputed: Date?, available: Bool) {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else {
            return (0, [:], nil, false)
        }

        let lastComputed = cache.lastComputedDate
            .flatMap { Self.dayFormatter.date(from: $0) }
            .map(startOfDay)

        // Without a valid cutoff we can't safely combine cache aggregates with a JSONL delta
        // (every day would route to JSONL while the cache's lifetime total still got added,
        // double-counting everything). Fail safe to pure JSONL: report no cache aggregates, and
        // let cacheAvailable be false so availability falls through to "did JSONL parse anything."
        guard let lastComputed else {
            return (0, [:], nil, false)
        }

        let allTime = (cache.modelUsage ?? [:]).values.reduce(0) { $0 + $1.amount(counting: kind) }

        // Always cache-inclusive: the CLI pre-sums dailyModelTokens and the split is not
        // recoverable from it. The cache-exclusive path therefore never reads this.
        var daily: [String: Int] = [:]
        for entry in cache.dailyModelTokens ?? [] {
            daily[entry.date, default: 0] += entry.tokensByModel.values.reduce(0, +)
        }

        return (allTime, daily, lastComputed, true)
    }

    // MARK: - Byte-level line scanning

    /// UTF-8 bytes of the `"usage"` JSON key, searched for as a cheap gate before decoding.
    private static let usageNeedle = Array("\"usage\"".utf8)

    /// Substring search over raw bytes within `buffer[lo..<hi]`.
    ///
    /// This replaces `Substring.contains("\"usage\"")`, which is grapheme-cluster aware and
    /// profiled at 37% of total scan time - 3.4x the cost of the JSON decoding it exists to
    /// avoid. The comment calling it a "cheap pre-filter" was measurably backwards.
    private static func containsUsageKey(_ buffer: UnsafeRawBufferPointer, from lo: Int, to hi: Int) -> Bool {
        let needle = usageNeedle
        let n = needle.count
        guard hi - lo >= n else { return false }
        let first = needle[0]
        var i = lo
        let last = hi - n
        while i <= last {
            if buffer[i] == first {
                var j = 1
                while j < n, buffer[i + j] == needle[j] { j += 1 }
                if j == n { return true }
            }
            i += 1
        }
        return false
    }

    /// Validates that `key` has the shape `DDDD-DD-DD` - digits in every digit position, `-` at
    /// indexes 4 and 7 - with a month in 01-12 and a day in 01-31.
    ///
    /// Day keys are the raw first 10 characters of a JSONL line's `timestamp` field, compared
    /// as strings against calendar-day bounds. Without this check, an impossible date like
    /// `"2026-07-32"` satisfies those string comparisons (it sorts between real dates) and its
    /// tokens land under a key that `windowSum` can never enumerate - invisible to 7D/30D but
    /// still summed into all-time. This narrows that problem rather than eliminating it: it is
    /// a shape check, not full calendar validation, so a shaped-but-impossible date whose month
    /// and day both fall within `01-31` (`2026-02-30`, `2026-04-31`, `2026-02-29` in a non-leap
    /// year, and similar) still passes and can still inflate all-time the same way. That gap is
    /// deliberately left open: CLI-emitted ISO-8601 timestamps never produce those shapes, and
    /// full calendar validation is out of scope for a per-line hot-path check. This runs per
    /// line, so it's a character-by-character shape check rather than a `DateFormatter`
    /// round trip.
    private static func isValidDayKey(_ key: some StringProtocol) -> Bool {
        guard key.count == 10 else { return false }
        // No per-line allocation: digits are folded into four locals as they're walked, rather
        // than collected into an array, since this runs on every usage-bearing line of every
        // scanned file (~100k times on a 20 MB session file).
        var monthTens = 0, monthOnes = 0, dayTens = 0, dayOnes = 0
        for (index, char) in key.enumerated() {
            if index == 4 || index == 7 {
                guard char == "-" else { return false }
                continue
            }
            guard let ascii = char.asciiValue, ascii >= 48, ascii <= 57 else { return false }
            let digit = Int(ascii - 48)
            switch index {
            case 5: monthTens = digit
            case 6: monthOnes = digit
            case 8: dayTens = digit
            case 9: dayOnes = digit
            default: break
            }
        }
        let month = monthTens * 10 + monthOnes
        let day = dayTens * 10 + dayOnes
        return (1...12).contains(month) && (1...31).contains(day)
    }

    // MARK: - JSONL scanning

    /// Walks `projectsDir` for `*.jsonl` files and sums `kind`'s token kinds per day, restricted
    /// to days within `range`.
    ///
    /// The cache cutoff is not a parameter: the caller folds it into `range.lowerBound`. Days at
    /// or before the cutoff are already inside `dailyModelTokens`, so the cache-inclusive caller
    /// starts the range the day after it, while the cache-exclusive caller — which cannot use
    /// `dailyModelTokens` at all — starts at the window's first day.
    ///
    /// Perf: files whose content-modification date predates `range.lowerBound` are skipped
    /// without being opened. A JSONL file only gains lines for a given day when the CLI writes
    /// them that day, so if its mtime is older than `range.lowerBound` it cannot contain any
    /// line we need.
    private func scanJSONL(
        projectsDir: URL,
        range: ClosedRange<Date>,
        counting kind: TokenKind
    ) -> (daily: [String: Int], anyParsed: Bool) {
        var daily: [String: Int] = [:]
        var anyParsed = false

        guard let enumerator = FileManager.default.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (daily, false)
        }

        // Day bounds as "yyyy-MM-dd" strings. That format sorts lexicographically in
        // chronological order, so string comparison replaces per-line Date parsing entirely.
        // The old path parsed the prefix into a Date only for `dayKey` to format it straight
        // back into the identical string, through two DateFormatter calls per line.
        let fromKey = dayKey(range.lowerBound)
        let toKey = dayKey(range.upperBound)

        let lineDecoder = JSONDecoder()

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }

            // Assumes a JSONL file's mtime tracks its latest appended line (true for normal CLI
            // writes); an externally-reset mtime could under-scan.
            if let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
               let mtime = values.contentModificationDate,
               mtime < range.lowerBound {
                continue
            }

            // Memory-mapped: these files reach ~20 MB and the old path materialised each one as
            // a String plus an array of Substrings. Claude Code only ever appends to them or
            // unlinks them wholesale, so the mapping cannot be truncated under us.
            //
            // Behavior change from the old `String(contentsOf:encoding:.utf8)` read: that
            // initializer is strict UTF-8, so a single invalid byte anywhere in the file made
            // the whole read return `nil` and the file was skipped entirely, before
            // `anyParsed` was ever set. `Data(contentsOf:options:.mappedIfSafe)` has no such
            // validation and succeeds on arbitrary bytes, so a file with e.g. one line
            // truncated mid multi-byte character by a crash now sets `anyParsed = true` and
            // contributes every other, decodable line instead of being dropped whole. This is
            // deliberate: one corrupt byte should not erase every token statistic for a file.
            guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { continue }
            anyParsed = true

            data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                let count = buffer.count
                var lineStart = 0
                var i = 0

                // `i <= count` so the final line is flushed even without a trailing newline.
                while i <= count {
                    if i == count || buffer[i] == UInt8(ascii: "\n") {
                        if i > lineStart, Self.containsUsageKey(buffer, from: lineStart, to: i) {
                            // No-copy slice over the mapped storage - `Data(bytes:count:)` would
                            // allocate and copy every candidate line. `JSONDecoder` accepts a
                            // slice directly; note it keeps `data`'s non-zero start index, so
                            // don't assume the slice is zero-based elsewhere.
                            let lineData = data[lineStart..<i]
                            if let line = try? lineDecoder.decode(Line.self, from: lineData),
                               let usage = line.message?.usage,
                               let timestamp = line.timestamp,
                               timestamp.count >= 10 {
                                let day = String(timestamp.prefix(10))
                                if Self.isValidDayKey(day), day >= fromKey, day <= toKey {
                                    daily[day, default: 0] += usage.amount(counting: kind)
                                }
                            }
                        }
                        lineStart = i + 1
                    }
                    i += 1
                }
            }
        }

        return (daily, anyParsed)
    }

    // MARK: - Window aggregation

    /// Sums the trailing `days`-day window ending at `today`, taking each day from the cache
    /// when it's on/before `cacheCutoff`, or from the JSONL delta otherwise.
    private func windowSum(
        days: Int,
        today: Date,
        cacheCutoff: Date,
        cacheDaily: [String: Int],
        deltaDaily: [String: Int]
    ) -> Int {
        var total = 0
        for offset in 0..<days {
            guard let day = Self.calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = dayKey(day)
            total += day <= cacheCutoff ? (cacheDaily[key] ?? 0) : (deltaDaily[key] ?? 0)
        }
        return total
    }
}
