# Cache-Exclusive Token Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a global toggle that switches the three Total Tokens menu-bar metrics between CLI-matching (cache-inclusive) and input+output-only accounting, on top of a byte-level scanner rewrite that makes the underlying JSONL scan ~15x faster.

**Architecture:** `TokenStatsService` gains two computation paths sharing one byte-level JSONL scanner parameterised by date range and token kind. Token stats move off the 30-second usage refresh onto their own 300-second coordinator. The toggle lives in `MenuBarIconConfiguration` alongside `showPaceMarker`.

**Tech Stack:** Swift 5, SwiftUI, XCTest, Xcode 26.x, macOS 14+.

**Spec:** `docs/superpowers/specs/2026-08-10-cache-exclusive-token-mode-design.md`

## Global Constraints

- **The 10 existing tests in `Claude UsageTests/TokenStatsServiceTests.swift` must never be edited.** They are the regression net proving cache-inclusive behavior is unchanged. If a change makes one fail, the change is wrong — not the test.
- **Default is cache-inclusive.** `countCacheTokens` defaults to `true` and decodes as `true` when absent, so no existing user's numbers change on upgrade.
- **Day keys are `"yyyy-MM-dd"` strings bucketed by the UTC date prefix of the JSONL `timestamp` field.** Never convert to local time before bucketing — the CLI buckets by UTC, and converting first silently shifts tokens across day boundaries.
- **Test command:** `xcodebuild test -project "Claude Usage.xcodeproj" -scheme "Claude Usage" -destination 'platform=macOS' -only-testing:"Claude UsageTests/<SuiteName>"`. Drop `-only-testing:` to run everything.
- **All 14 locales get every new string key:** `de`, `en`, `es`, `fr`, `it`, `ja`, `ko`, `pt-BR`, `pt`, `tr`, `uk`, `vi`, `zh-Hant`, `zh-ch`. A missing key renders as the raw key — there is no fallback layer.
- Commit after every task, and **every commit must build and pass the suite**. Conventional-commit prefixes (`perf:`, `feat:`, `refactor:`, `test:`).
- **Execution order is 1, 2, 3, 4, 5, 7, 6, 8.** Task 7 is pulled ahead of Task 6 because Task 6 reads the property Task 7 adds; the numbering is left alone so file references stay stable.

---

## File Structure

| File | Responsibility | Phase |
|---|---|---|
| `Claude Usage/Shared/Services/TokenStatsService.swift` | Byte scanner, both computation paths | 0, 1 |
| `Claude UsageTests/TokenStatsServiceTests.swift` | Existing suite — **read-only** | — |
| `Claude UsageTests/TokenStatsScannerTests.swift` | **New.** Byte-scanner edge cases | 0 |
| `Claude UsageTests/TokenStatsExclusiveModeTests.swift` | **New.** Cache-exclusive path | 1 |
| `Claude Usage/MenuBar/TokenStatsRefreshCoordinator.swift` | **New.** 300s timer + `isLoading` guard | 2 |
| `Claude UsageTests/TokenStatsRefreshCoordinatorTests.swift` | **New.** Re-entrancy guard | 2 |
| `Claude Usage/MenuBar/MenuBarManager.swift` | Drop inline load, own the coordinator | 2 |
| `Claude Usage/Shared/Models/MenuBarIconConfig.swift` | `countCacheTokens` + Codable | 3 |
| `Claude UsageTests/MenuBarIconConfigTests.swift` | **New.** Backwards-compatible decode | 3 |
| `Claude Usage/Views/Settings/Profile/AppearanceSettingsView.swift` | Toggle row | 3 |
| `Claude Usage/Resources/*.lproj/Localizable.strings` | 2 new keys × 14 files | 3 |

---

# PHASE 0 — Byte-level scanner rewrite

No behavior change. Ships and merges on its own.

## Task 1: Replace `.convertFromSnakeCase` with explicit `CodingKeys`

**Files:**
- Modify: `Claude Usage/Shared/Services/TokenStatsService.swift:55-70` (the `Line` struct), `:233` (decoder setup)
- Test: existing `Claude UsageTests/TokenStatsServiceTests.swift` (unchanged, used as the gate)

**Interfaces:**
- Consumes: nothing
- Produces: `TokenStatsService.Line.Message.Usage` with explicit `CodingKeys`; the `lineDecoder` no longer sets `keyDecodingStrategy`.

- [ ] **Step 1: Run the existing suite to confirm a green baseline**

```bash
cd "/Users/mac/Github/haitranwang/self/Claude-Usage-Tracker"
xcodebuild test -project "Claude Usage.xcodeproj" -scheme "Claude Usage" \
  -destination 'platform=macOS' \
  -only-testing:"Claude UsageTests/TokenStatsServiceTests" 2>&1 | tail -15
```

Expected: `** TEST SUCCEEDED **` and 10 passing test cases. If this is not green, stop — the baseline is broken and nothing below is meaningful.

- [ ] **Step 2: Add explicit `CodingKeys` to the `Usage` struct**

Replace the `Line` struct in `TokenStatsService.swift` (currently at lines 55-70) with:

```swift
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

                var total: Int {
                    (inputTokens ?? 0) + (outputTokens ?? 0)
                        + (cacheReadInputTokens ?? 0) + (cacheCreationInputTokens ?? 0)
                }
            }
            let usage: Usage?
        }
        let message: Message?
        let timestamp: String?
    }
```

- [ ] **Step 3: Drop the snake-case strategy from the decoder**

In `scanJSONL`, replace these two lines:

```swift
        let lineDecoder = JSONDecoder()
        lineDecoder.keyDecodingStrategy = .convertFromSnakeCase
```

with:

```swift
        let lineDecoder = JSONDecoder()
```

- [ ] **Step 4: Run the suite — it must still be green**

```bash
xcodebuild test -project "Claude Usage.xcodeproj" -scheme "Claude Usage" \
  -destination 'platform=macOS' \
  -only-testing:"Claude UsageTests/TokenStatsServiceTests" 2>&1 | tail -15
```

Expected: `** TEST SUCCEEDED **`, same 10 tests. The fixtures in that file use `input_tokens` / `cache_read_input_tokens` spellings, so they exercise the new `CodingKeys` directly.

- [ ] **Step 5: Commit**

```bash
git add "Claude Usage/Shared/Services/TokenStatsService.swift"
git commit -m "perf(tokens): decode JSONL usage with explicit CodingKeys

.convertFromSnakeCase transforms every key of every decoded object,
including the many this struct ignores. Profiled at 11% of scan time."
```

---

## Task 2: Byte-level line splitting and `"usage"` search

**Files:**
- Modify: `Claude Usage/Shared/Services/TokenStatsService.swift` — `scanJSONL` body, and delete `dayFromTimestamp`
- Create: `Claude UsageTests/TokenStatsScannerTests.swift`

**Interfaces:**
- Consumes: `Line` with `CodingKeys` from Task 1
- Produces: `scanJSONL(projectsDir:cacheCutoff:scanFrom:today:) -> (daily: [String: Int], anyParsed: Bool)` — **signature unchanged**, internals rewritten. Private static helper `containsUsageKey(_:from:to:) -> Bool`.

- [ ] **Step 1: Write the failing edge-case tests**

Create `Claude UsageTests/TokenStatsScannerTests.swift`:

```swift
import XCTest
@testable import Claude_Usage

/// Edge cases for the byte-level JSONL scanner. Line splitting on raw bytes is where
/// off-by-one bugs live, and the production corpus does not reliably contain these shapes.
final class TokenStatsScannerTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStatsScannerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        try super.tearDownWithError()
    }

    private let referenceDate = Date()

    private lazy var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }()

    private lazy var dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func day(offsetFromToday offset: Int) -> String {
        let today = calendar.startOfDay(for: referenceDate)
        return dayFormatter.string(from: calendar.date(byAdding: .day, value: offset, to: today)!)
    }

    /// Writes raw file bytes verbatim - no trailing newline is appended.
    private func writeRawJSONL(_ body: String) -> URL {
        let projectsDir = tempDir.appendingPathComponent("projects/p")
        try! FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        try! body.write(
            to: projectsDir.appendingPathComponent("session.jsonl"),
            atomically: true, encoding: .utf8
        )
        return projectsDir.deletingLastPathComponent()
    }

    private func line(_ day: String, input: Int, output: Int) -> String {
        """
        {"type":"assistant","timestamp":"\(day)T12:00:00.000Z","message":{"usage":{"input_tokens":\(input),"output_tokens":\(output)}}}
        """
    }

    private func allTime(_ projectsDir: URL) -> Int {
        TokenStatsService().load(
            enabledFrames: [.tokensAllTime],
            statsURL: tempDir.appendingPathComponent("no-such-cache.json"),
            projectsDir: projectsDir,
            referenceDate: referenceDate
        ).allTime
    }

    // MARK: - Tests

    func testFinalLineWithoutTrailingNewlineIsCounted() {
        // The scanner walks to `i == count` to flush a last line that has no "\n" after it.
        // Off by one here silently drops the most recent entry in every actively-written file.
        let dir = writeRawJSONL(line(day(offsetFromToday: -1), input: 10, output: 5))
        XCTAssertEqual(allTime(dir), 15)
    }

    func testFinalLineWithTrailingNewlineIsNotDoubleCounted() {
        let dir = writeRawJSONL(line(day(offsetFromToday: -1), input: 10, output: 5) + "\n")
        XCTAssertEqual(allTime(dir), 15, "trailing newline must not produce a second, empty line")
    }

    func testBlankLinesBetweenEntriesAreSkipped() {
        let d = day(offsetFromToday: -1)
        let dir = writeRawJSONL(line(d, input: 10, output: 5) + "\n\n\n" + line(d, input: 1, output: 2))
        XCTAssertEqual(allTime(dir), 18)
    }

    func testEmptyFileIsHarmless() {
        let dir = writeRawJSONL("")
        XCTAssertEqual(allTime(dir), 0)
    }

    func testLineWithoutUsageKeyIsSkipped() {
        let d = day(offsetFromToday: -1)
        let userLine = """
        {"type":"user","timestamp":"\(d)T09:00:00.000Z","message":{"content":"hello"}}
        """
        let dir = writeRawJSONL(userLine + "\n" + line(d, input: 7, output: 3))
        XCTAssertEqual(allTime(dir), 10)
    }

    func testUnparseableTimestampIsRejected() {
        // Day keys are compared as strings; garbage must not slip past the range check.
        let bad = """
        {"type":"assistant","timestamp":"not-a-real-timestamp","message":{"usage":{"input_tokens":999,"output_tokens":999}}}
        """
        let dir = writeRawJSONL(bad + "\n" + line(day(offsetFromToday: -1), input: 4, output: 1))
        XCTAssertEqual(allTime(dir), 5)
    }
}
```

- [ ] **Step 2: Run the new tests to verify they fail**

```bash
xcodebuild test -project "Claude Usage.xcodeproj" -scheme "Claude Usage" \
  -destination 'platform=macOS' \
  -only-testing:"Claude UsageTests/TokenStatsScannerTests" 2>&1 | tail -20
```

Expected: build succeeds, `testFinalLineWithoutTrailingNewlineIsCounted` **passes** already (the current `split(separator:)` handles it), and the suite is green. This is a characterisation suite — it locks in behavior *before* the rewrite so the rewrite cannot change it. If any test fails here, the expectation is wrong; fix the test, not the code.

- [ ] **Step 3: Commit the characterisation tests before touching the scanner**

```bash
git add "Claude UsageTests/TokenStatsScannerTests.swift"
git commit -m "test(tokens): characterise JSONL scanner edge cases

Locks in line-splitting behavior before the byte-level rewrite so the
rewrite is provably behavior-preserving."
```

- [ ] **Step 4: Add the byte-level needle search helper**

Add to `TokenStatsService`, just above the `// MARK: - JSONL scanning` section:

```swift
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
```

- [ ] **Step 5: Rewrite the `scanJSONL` body**

Replace the whole body of `scanJSONL` (keeping its existing signature and doc comment) with:

```swift
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
        let cutoffKey = cacheCutoff == .distantPast ? "" : dayKey(cacheCutoff)
        let fromKey = dayKey(scanFrom)
        let toKey = dayKey(today)

        let lineDecoder = JSONDecoder()

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }

            // Assumes a JSONL file's mtime tracks its latest appended line (true for normal CLI
            // writes); an externally-reset mtime could under-scan.
            if let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
               let mtime = values.contentModificationDate,
               mtime < scanFrom {
                continue
            }

            // Memory-mapped: these files reach ~20 MB and the old path materialised each one as
            // a String plus an array of Substrings. Claude Code only ever appends to them or
            // unlinks them wholesale, so the mapping cannot be truncated under us.
            guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { continue }
            anyParsed = true

            data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                guard let base = buffer.baseAddress else { return }
                let count = buffer.count
                var lineStart = 0
                var i = 0

                // `i <= count` so the final line is flushed even without a trailing newline.
                while i <= count {
                    if i == count || buffer[i] == UInt8(ascii: "\n") {
                        if i > lineStart, Self.containsUsageKey(buffer, from: lineStart, to: i) {
                            let lineData = Data(bytes: base.advanced(by: lineStart), count: i - lineStart)
                            if let line = try? lineDecoder.decode(Line.self, from: lineData),
                               let usage = line.message?.usage,
                               let timestamp = line.timestamp,
                               timestamp.count >= 10 {
                                let day = String(timestamp.prefix(10))
                                if day > cutoffKey, day >= fromKey, day <= toKey {
                                    daily[day, default: 0] += usage.total
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
```

- [ ] **Step 6: Delete the now-unused `dayFromTimestamp`**

Remove these lines from `TokenStatsService.swift` (currently 103-108):

```swift
    /// Parses the "yyyy-MM-dd" prefix of an ISO8601 timestamp into a start-of-day `Date`.
    private func dayFromTimestamp(_ timestamp: String) -> Date? {
        guard timestamp.count >= 10 else { return nil }
        guard let date = Self.dayFormatter.date(from: String(timestamp.prefix(10))) else { return nil }
        return startOfDay(date)
    }
```

`dayKey`, `startOfDay`, `dayAfter` and `Self.dayFormatter` all stay — `readCache` and `windowSum` still use them.

- [ ] **Step 7: Run both suites — all must pass unchanged**

```bash
xcodebuild test -project "Claude Usage.xcodeproj" -scheme "Claude Usage" \
  -destination 'platform=macOS' \
  -only-testing:"Claude UsageTests/TokenStatsServiceTests" \
  -only-testing:"Claude UsageTests/TokenStatsScannerTests" 2>&1 | grep -E "Test case .* (passed|failed)|TEST (SUCCEEDED|FAILED)"
```

Expected: `** TEST SUCCEEDED **`, 16 test cases passing (10 existing + 6 new), zero failures. Any failure means the rewrite changed behavior — fix the scanner, never the tests.

- [ ] **Step 8: Run the full suite**

```bash
xcodebuild test -project "Claude Usage.xcodeproj" -scheme "Claude Usage" \
  -destination 'platform=macOS' 2>&1 | grep -cE "Test case .* failed"
```

Expected output: `0`

- [ ] **Step 9: Commit**

```bash
git add "Claude Usage/Shared/Services/TokenStatsService.swift"
git commit -m "perf(tokens): scan JSONL over raw bytes instead of String

Profiling showed only 5% of scan time was disk I/O. The rest was Swift
String overhead: the grapheme-aware \"usage\" prefilter at 37%, line
splitting at 30%, and a DateFormatter round trip at 17% that parsed a
day string into a Date purely so it could be formatted back into the
identical string.

Replaces all three with mmap + byte scanning + string day-key compares.
Measured 15.3x faster over 7 days and 7.0x over 30, with byte-identical
per-day output."
```

---

# PHASE 1 — Cache-exclusive computation path

## Task 3: Introduce `TokenKind` and range-based scanning

**Files:**
- Modify: `Claude Usage/Shared/Services/TokenStatsService.swift`
- Test: existing suites (gate only — no new tests in this task)

**Interfaces:**
- Consumes: byte scanner from Task 2
- Produces:
  - `TokenStatsService.TokenKind` — `enum { case all, inputOutputOnly }`
  - `Line.Message.Usage.amount(counting: TokenKind) -> Int` (replaces `total`)
  - `Cache.Model.amount(counting: TokenKind) -> Int` (replaces `total`)
  - `scanJSONL(projectsDir: URL, range: ClosedRange<Date>, counting: TokenKind) -> (daily: [String: Int], anyParsed: Bool)`
  - `readCache(from: URL, counting: TokenKind) -> (allTime: Int, daily: [String: Int], lastComputed: Date?, available: Bool)`

- [ ] **Step 1: Add the `TokenKind` enum**

Add near the top of `struct TokenStatsService`, above `// MARK: - stats-cache.json decoding`:

```swift
    /// Which token kinds a total counts.
    ///
    /// `.all` is what `claude` reports and what `dailyModelTokens` stores since CLI 2.1.221.
    /// `.inputOutputOnly` is the pre-2.1.221 meaning, kept available because cache reads are
    /// ~95% of `.all` and bill at a fraction of input tokens.
    enum TokenKind {
        case all
        case inputOutputOnly
    }
```

- [ ] **Step 2: Replace both `total` properties with `amount(counting:)`**

In `Cache.Model`, replace:

```swift
            var total: Int {
                (inputTokens ?? 0) + (outputTokens ?? 0)
                    + (cacheReadInputTokens ?? 0) + (cacheCreationInputTokens ?? 0)
            }
```

with:

```swift
            func amount(counting kind: TokenKind) -> Int {
                let io = (inputTokens ?? 0) + (outputTokens ?? 0)
                switch kind {
                case .inputOutputOnly: return io
                case .all: return io + (cacheReadInputTokens ?? 0) + (cacheCreationInputTokens ?? 0)
                }
            }
```

In `Line.Message.Usage`, replace:

```swift
                var total: Int {
                    (inputTokens ?? 0) + (outputTokens ?? 0)
                        + (cacheReadInputTokens ?? 0) + (cacheCreationInputTokens ?? 0)
                }
```

with:

```swift
                func amount(counting kind: TokenKind) -> Int {
                    let io = (inputTokens ?? 0) + (outputTokens ?? 0)
                    switch kind {
                    case .inputOutputOnly: return io
                    case .all: return io + (cacheReadInputTokens ?? 0) + (cacheCreationInputTokens ?? 0)
                    }
                }
```

- [ ] **Step 3: Re-sign `readCache` to take a kind**

Change the signature and the `allTime` line:

```swift
    private func readCache(
        from url: URL,
        counting kind: TokenKind
    ) -> (allTime: Int, daily: [String: Int], lastComputed: Date?, available: Bool) {
```

and

```swift
        let allTime = (cache.modelUsage ?? [:]).values.reduce(0) { $0 + $1.amount(counting: kind) }
```

`dailyModelTokens` is stored pre-summed by the CLI and is always cache-inclusive, so the `daily` dictionary build is unchanged and ignores `kind`. Add this note above it:

```swift
        // Always cache-inclusive: the CLI pre-sums dailyModelTokens and the split is not
        // recoverable from it. The cache-exclusive path therefore never reads this.
```

- [ ] **Step 4: Re-sign `scanJSONL` to take a range and a kind**

Change the signature to:

```swift
    private func scanJSONL(
        projectsDir: URL,
        range: ClosedRange<Date>,
        counting kind: TokenKind
    ) -> (daily: [String: Int], anyParsed: Bool) {
```

Inside, replace the three key computations:

```swift
        let cutoffKey = cacheCutoff == .distantPast ? "" : dayKey(cacheCutoff)
        let fromKey = dayKey(scanFrom)
        let toKey = dayKey(today)
```

with:

```swift
        let fromKey = dayKey(range.lowerBound)
        let toKey = dayKey(range.upperBound)
```

replace the mtime comparison `mtime < scanFrom` with `mtime < range.lowerBound`, replace the day filter:

```swift
                                if day > cutoffKey, day >= fromKey, day <= toKey {
                                    daily[day, default: 0] += usage.total
                                }
```

with:

```swift
                                if day >= fromKey, day <= toKey {
                                    daily[day, default: 0] += usage.amount(counting: kind)
                                }
```

and update the doc comment's first line to:

```swift
    /// Walks `projectsDir` for `*.jsonl` files and sums `kind`'s token kinds per day, restricted
    /// to days within `range`.
    ///
    /// The cache cutoff is not a parameter: the caller folds it into `range.lowerBound`. Days at
    /// or before the cutoff are already inside `dailyModelTokens`, so the cache-inclusive caller
    /// starts the range the day after it, while the cache-exclusive caller — which cannot use
    /// `dailyModelTokens` at all — starts at the window's first day.
```

- [ ] **Step 5: Update the single existing call site in `load`**

Replace:

```swift
        let (deltaDaily, anyJSONLParsed) = scanJSONL(
            projectsDir: projectsDir,
            cacheCutoff: cacheCutoff,
            scanFrom: scanFrom,
            today: today
        )
```

with:

```swift
        // A cutoff on or after today makes `dayAfter(cutoff) > today`, which would trap when
        // constructing the range. That happens routinely — the CLI advances lastComputedDate to
        // today whenever it recomputes — and means the cache already covers everything.
        let (deltaDaily, anyJSONLParsed): ([String: Int], Bool) = scanFrom <= today
            ? scanJSONL(projectsDir: projectsDir, range: scanFrom...today, counting: .all)
            : ([:], false)
```

and update `readCache`'s call:

```swift
        let (cacheAllTime, cacheDaily, lastComputed, cacheAvailable) = readCache(from: statsURL, counting: .all)
```

- [ ] **Step 6: Run all suites**

```bash
xcodebuild test -project "Claude Usage.xcodeproj" -scheme "Claude Usage" \
  -destination 'platform=macOS' 2>&1 | grep -cE "Test case .* failed"
```

Expected output: `0`. This is a pure refactor — every existing expectation must hold.

- [ ] **Step 7: Commit**

```bash
git add "Claude Usage/Shared/Services/TokenStatsService.swift"
git commit -m "refactor(tokens): parameterise scan by date range and token kind

Folds the cache cutoff into the scan range and makes the counted token
kinds explicit, so a cache-exclusive path can reuse the same scanner.
Also guards the cutoff-on-or-after-today case, which would trap when
constructing a ClosedRange."
```

---

## Task 4: Add the cache-exclusive path to `load`

**Files:**
- Modify: `Claude Usage/Shared/Services/TokenStatsService.swift`
- Create: `Claude UsageTests/TokenStatsExclusiveModeTests.swift`

**Interfaces:**
- Consumes: `TokenKind`, range-based `scanJSONL`, `readCache(from:counting:)` from Task 3
- Produces: `load(enabledFrames:countCacheTokens:statsURL:projectsDir:referenceDate:) -> TokenStats` — new second parameter, defaulting to `true`.

- [ ] **Step 1: Write the failing tests**

Create `Claude UsageTests/TokenStatsExclusiveModeTests.swift`:

```swift
import XCTest
@testable import Claude_Usage

/// Cache-exclusive mode: input + output only, windows read straight from JSONL.
///
/// The critical difference from cache-inclusive mode is the cutoff. With cache on, JSONL lines
/// on or before `lastComputedDate` are skipped because `dailyModelTokens` already contains them.
/// With cache off, `dailyModelTokens` is unusable and those same lines are the *only* source -
/// so they must be counted. Reusing the inclusive filter silently zeroes most of the window.
final class TokenStatsExclusiveModeTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStatsExclusiveModeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        try super.tearDownWithError()
    }

    private let referenceDate = Date()

    private lazy var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }()

    private lazy var dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func day(offsetFromToday offset: Int) -> String {
        let today = calendar.startOfDay(for: referenceDate)
        return dayFormatter.string(from: calendar.date(byAdding: .day, value: offset, to: today)!)
    }

    private func writeStatsCache(_ json: String) -> URL {
        let url = tempDir.appendingPathComponent("stats-cache.json")
        try! json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeJSONL(
        _ lines: [(day: String, input: Int, output: Int, cacheRead: Int, cacheCreate: Int)]
    ) -> URL {
        let projectsDir = tempDir.appendingPathComponent("projects/p")
        try! FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        let body = lines.map { l in
            """
            {"type":"assistant","timestamp":"\(l.day)T12:00:00.000Z","message":{"usage":{"input_tokens":\(l.input),"output_tokens":\(l.output),"cache_read_input_tokens":\(l.cacheRead),"cache_creation_input_tokens":\(l.cacheCreate)}}}
            """
        }.joined(separator: "\n")
        try! body.write(to: projectsDir.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        return projectsDir.deletingLastPathComponent()
    }

    private func load(_ frames: Set<MenuBarMetricType>, statsURL: URL, projectsDir: URL) -> TokenStats {
        TokenStatsService().load(
            enabledFrames: frames,
            countCacheTokens: false,
            statsURL: statsURL,
            projectsDir: projectsDir,
            referenceDate: referenceDate
        )
    }

    // MARK: - Tests

    func testExclusiveWindowCountsDaysBeforeCutoff() {
        // Cutoff is 2 days ago. A JSONL line 4 days ago sits *before* it - cache-inclusive mode
        // would skip it. Cache-exclusive mode must count it, because dailyModelTokens (which
        // holds a deliberately absurd 999999 for that day) cannot be used at all.
        let cutoff = day(offsetFromToday: -2)
        let statsURL = writeStatsCache("""
        {
          "modelUsage": {},
          "dailyModelTokens": [ { "date": "\(day(offsetFromToday: -4))", "tokensByModel": { "m": 999999 } } ],
          "lastComputedDate": "\(cutoff)"
        }
        """)
        let dir = writeJSONL([
            (day: day(offsetFromToday: -4), input: 10, output: 5, cacheRead: 700, cacheCreate: 30)
        ])

        let stats = load([.tokens7Days], statsURL: statsURL, projectsDir: dir)

        XCTAssertTrue(stats.isAvailable)
        XCTAssertEqual(stats.last7Days, 15, "pre-cutoff day counted from JSONL, cache tokens excluded")
    }

    func testExclusiveModeExcludesCacheTokens() {
        // A pure cache-read line contributes nothing at all with cache off.
        let cutoff = day(offsetFromToday: -3)
        let statsURL = writeStatsCache("""
        { "modelUsage": {}, "dailyModelTokens": [], "lastComputedDate": "\(cutoff)" }
        """)
        let dir = writeJSONL([
            (day: day(offsetFromToday: -1), input: 0, output: 0, cacheRead: 500_000, cacheCreate: 9_000),
            (day: day(offsetFromToday: -1), input: 12, output: 8, cacheRead: 0, cacheCreate: 0)
        ])

        let stats = load([.tokens7Days], statsURL: statsURL, projectsDir: dir)

        XCTAssertEqual(stats.last7Days, 20, "only the 12 + 8 input/output line counts")
    }

    func testExclusiveAllTimeUsesModelUsageInputOutputOnly() {
        let cutoff = day(offsetFromToday: -1)
        let statsURL = writeStatsCache("""
        {
          "modelUsage": {
            "m": {
              "inputTokens": 700, "outputTokens": 300,
              "cacheReadInputTokens": 9000000, "cacheCreationInputTokens": 40000
            }
          },
          "dailyModelTokens": [],
          "lastComputedDate": "\(cutoff)"
        }
        """)
        let dir = writeJSONL([
            (day: cutoff, input: 55, output: 5, cacheRead: 8_000, cacheCreate: 100)
        ])

        let stats = load([.tokensAllTime], statsURL: statsURL, projectsDir: dir)

        XCTAssertEqual(
            stats.allTime, 1000,
            "modelUsage input+output only; the on-cutoff JSONL line is already inside it"
        )
    }

    func testExclusiveAllTimeAddsPostCutoffJSONLInputOutput() {
        let cutoff = day(offsetFromToday: -2)
        let statsURL = writeStatsCache("""
        {
          "modelUsage": {
            "m": {
              "inputTokens": 700, "outputTokens": 300,
              "cacheReadInputTokens": 9000000, "cacheCreationInputTokens": 40000
            }
          },
          "dailyModelTokens": [],
          "lastComputedDate": "\(cutoff)"
        }
        """)
        let dir = writeJSONL([
            (day: day(offsetFromToday: -1), input: 40, output: 10, cacheRead: 8_000, cacheCreate: 100)
        ])

        let stats = load([.tokensAllTime], statsURL: statsURL, projectsDir: dir)

        XCTAssertEqual(stats.allTime, 1050, "1000 cached + 50 io from the post-cutoff day")
    }

    func testExclusiveFramesAreMutuallyConsistent() {
        // The bug that started all of this: frames measuring different quantities, so a 7-day
        // window could exceed all-time. Whatever the numbers, this ordering must hold.
        let cutoff = day(offsetFromToday: -2)
        let statsURL = writeStatsCache("""
        {
          "modelUsage": { "m": { "inputTokens": 5000, "outputTokens": 1000,
                                 "cacheReadInputTokens": 900000, "cacheCreationInputTokens": 4000 } },
          "dailyModelTokens": [],
          "lastComputedDate": "\(cutoff)"
        }
        """)
        let dir = writeJSONL([
            (day: day(offsetFromToday: -20), input: 100, output: 20, cacheRead: 5_000, cacheCreate: 50),
            (day: day(offsetFromToday: -3), input: 30, output: 7, cacheRead: 5_000, cacheCreate: 50),
            (day: day(offsetFromToday: -1), input: 11, output: 2, cacheRead: 5_000, cacheCreate: 50)
        ])

        let stats = load([.tokensAllTime, .tokens7Days, .tokens30Days], statsURL: statsURL, projectsDir: dir)

        XCTAssertEqual(stats.last7Days, 50, "37 + 13 within 7 days")
        XCTAssertEqual(stats.last30Days, 170, "120 + 37 + 13 within 30 days")
        XCTAssertGreaterThanOrEqual(stats.last30Days, stats.last7Days)
        XCTAssertGreaterThanOrEqual(stats.allTime, stats.last7Days)
    }

    func testInclusiveModeStillDefaultsOn() {
        // The parameter defaults to true, so an unmigrated call site keeps CLI-matching numbers.
        let cutoff = day(offsetFromToday: -1)
        let statsURL = writeStatsCache("""
        {
          "modelUsage": { "m": { "inputTokens": 10, "outputTokens": 5,
                                 "cacheReadInputTokens": 1000, "cacheCreationInputTokens": 100 } },
          "dailyModelTokens": [],
          "lastComputedDate": "\(cutoff)"
        }
        """)
        let dir = writeJSONL([(day: cutoff, input: 1, output: 1, cacheRead: 1, cacheCreate: 1)])

        let stats = TokenStatsService().load(
            enabledFrames: [.tokensAllTime],
            statsURL: statsURL,
            projectsDir: dir,
            referenceDate: referenceDate
        )

        XCTAssertEqual(stats.allTime, 1115, "all four kinds: 10 + 5 + 1000 + 100")
    }
}
```

- [ ] **Step 2: Run the new tests to verify they fail**

```bash
xcodebuild test -project "Claude Usage.xcodeproj" -scheme "Claude Usage" \
  -destination 'platform=macOS' \
  -only-testing:"Claude UsageTests/TokenStatsExclusiveModeTests" 2>&1 | tail -20
```

Expected: **compile error** — `load` has no `countCacheTokens:` parameter yet. That is the failing state for this step.

- [ ] **Step 3: Split `load` into two paths**

Replace the entire `load` method with:

```swift
    /// Loads token stats for exactly the requested frames.
    ///
    /// - Parameters:
    ///   - enabledFrames: Menu-bar metrics currently enabled. Non-token metrics are ignored.
    ///     Frames not present here are left at 0 - this is the load-reduction that keeps the
    ///     JSONL scan bounded to only what's actually displayed.
    ///   - countCacheTokens: `true` reports what `claude` reports (input + output + cache read +
    ///     cache creation). `false` counts only input + output.
    /// - Returns: `.unavailable` when neither the cache nor any JSONL file could be read, or
    ///   when no token frame is enabled.
    func load(
        enabledFrames: Set<MenuBarMetricType>,
        countCacheTokens: Bool = true,
        statsURL: URL = Constants.ClaudePaths.statsCacheFile,
        projectsDir: URL = Constants.ClaudePaths.projectsDirectory,
        referenceDate: Date = Date()
    ) -> TokenStats {
        let tokenFrames = enabledFrames.filter { $0.isTokenMetric }
        guard !tokenFrames.isEmpty else { return .unavailable }

        let today = startOfDay(referenceDate)
        return countCacheTokens
            ? loadCacheInclusive(tokenFrames: tokenFrames, statsURL: statsURL, projectsDir: projectsDir, today: today)
            : loadCacheExclusive(tokenFrames: tokenFrames, statsURL: statsURL, projectsDir: projectsDir, today: today)
    }

    /// Windows come from the CLI's pre-summed `dailyModelTokens`, with JSONL supplying only the
    /// days after `lastComputedDate` that the cache has not folded in yet.
    private func loadCacheInclusive(
        tokenFrames: Set<MenuBarMetricType>,
        statsURL: URL,
        projectsDir: URL,
        today: Date
    ) -> TokenStats {
        let (cacheAllTime, cacheDaily, lastComputed, cacheAvailable) = readCache(from: statsURL, counting: .all)

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

    /// Windows come entirely from JSONL: `dailyModelTokens` bakes cache tokens in and the split
    /// is not recoverable, so the cutoff plays no part in the window arithmetic here. All-time
    /// still starts from `modelUsage`, whose input/output fields kept their pre-2.1.221 meaning.
    private func loadCacheExclusive(
        tokenFrames: Set<MenuBarMetricType>,
        statsURL: URL,
        projectsDir: URL,
        today: Date
    ) -> TokenStats {
        let (cacheIOAllTime, _, lastComputed, cacheAvailable) = readCache(from: statsURL, counting: .inputOutputOnly)
        let cacheCutoff = lastComputed ?? .distantPast

        // All-time needs the days the cache has not folded in yet; windows need their whole span.
        // The scan starts at whichever is earlier, so one pass serves every enabled frame.
        var scanFrom: Date?
        if tokenFrames.contains(.tokensAllTime) {
            scanFrom = dayAfter(cacheCutoff)
        }
        let maxWindow = tokenFrames.contains(.tokens30Days) ? 30 : (tokenFrames.contains(.tokens7Days) ? 7 : 0)
        if maxWindow > 0 {
            let windowStart = Self.calendar.date(byAdding: .day, value: -(maxWindow - 1), to: today) ?? today
            scanFrom = scanFrom.map { min($0, windowStart) } ?? windowStart
        }

        let (daily, anyJSONLParsed): ([String: Int], Bool) = {
            guard let from = scanFrom, from <= today else { return ([:], false) }
            return scanJSONL(projectsDir: projectsDir, range: from...today, counting: .inputOutputOnly)
        }()

        var allTime = 0
        var last7Days = 0
        var last30Days = 0

        if tokenFrames.contains(.tokensAllTime) {
            // `daily` may reach back before the cutoff to serve a window, so all-time takes only
            // the days the cache has not already counted.
            let cutoffKey = cacheCutoff == .distantPast ? "" : dayKey(cacheCutoff)
            let afterCutoff = daily.reduce(0) { $1.key > cutoffKey ? $0 + $1.value : $0 }
            allTime = cacheIOAllTime + afterCutoff
        }
        if tokenFrames.contains(.tokens7Days) {
            last7Days = jsonlWindowSum(days: 7, today: today, daily: daily)
        }
        if tokenFrames.contains(.tokens30Days) {
            last30Days = jsonlWindowSum(days: 30, today: today, daily: daily)
        }

        guard cacheAvailable || anyJSONLParsed else { return .unavailable }

        return TokenStats(allTime: allTime, last7Days: last7Days, last30Days: last30Days, isAvailable: true)
    }
```

- [ ] **Step 4: Add the JSONL-only window helper**

Add directly below the existing `windowSum` method:

```swift
    /// Sums the trailing `days`-day window ending at `today` from JSONL data alone.
    ///
    /// Unlike `windowSum` there is no cutoff branch: in cache-exclusive mode every day in the
    /// window comes from `daily`, including days the CLI has already folded into its cache.
    private func jsonlWindowSum(days: Int, today: Date, daily: [String: Int]) -> Int {
        var total = 0
        for offset in 0..<days {
            guard let day = Self.calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            total += daily[dayKey(day)] ?? 0
        }
        return total
    }
```

- [ ] **Step 5: Run the new tests to verify they pass**

```bash
xcodebuild test -project "Claude Usage.xcodeproj" -scheme "Claude Usage" \
  -destination 'platform=macOS' \
  -only-testing:"Claude UsageTests/TokenStatsExclusiveModeTests" 2>&1 | grep -E "Test case .* (passed|failed)|TEST (SUCCEEDED|FAILED)"
```

Expected: `** TEST SUCCEEDED **`, 6 test cases passing.

- [ ] **Step 6: Run the full suite**

```bash
xcodebuild test -project "Claude Usage.xcodeproj" -scheme "Claude Usage" \
  -destination 'platform=macOS' 2>&1 | grep -cE "Test case .* failed"
```

Expected output: `0`

- [ ] **Step 7: Commit**

```bash
git add "Claude Usage/Shared/Services/TokenStatsService.swift" \
        "Claude UsageTests/TokenStatsExclusiveModeTests.swift"
git commit -m "feat(tokens): add cache-exclusive computation path

Windows read straight from JSONL because dailyModelTokens bakes cache
tokens in irreversibly; all-time starts from modelUsage, whose
input/output fields kept their pre-2.1.221 meaning. Defaults off, so
existing behavior is untouched."
```

---

# PHASE 2 — Dedicated refresh cadence

## Task 5: `TokenStatsRefreshCoordinator`

**Files:**
- Create: `Claude Usage/MenuBar/TokenStatsRefreshCoordinator.swift`
- Create: `Claude UsageTests/TokenStatsRefreshCoordinatorTests.swift`

**Interfaces:**
- Consumes: `TokenStatsService.load(enabledFrames:countCacheTokens:...)` from Task 4
- Produces:
  - `protocol TokenStatsRefreshCoordinatorDelegate: AnyObject { func tokenStatsCoordinator(_:didLoad: TokenStats) }`
  - `protocol TokenStatsInputProviding: AnyObject { var enabledTokenFrames: Set<MenuBarMetricType> { get }; var countCacheTokens: Bool { get } }`
  - `final class TokenStatsRefreshCoordinator` with `start()`, `stop()`, `refreshNow()`, `var isLoading: Bool { get }`

- [ ] **Step 1: Write the failing tests**

Create `Claude UsageTests/TokenStatsRefreshCoordinatorTests.swift`:

```swift
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
        let coordinator = makeCoordinator(input: StubInput(), delegate: delegate) { _, _ in
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

        let coordinator = makeCoordinator(input: StubInput(), delegate: delegate) { _, _ in
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

        let coordinator = makeCoordinator(input: StubInput(), delegate: delegate) { _, _ in
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
```

- [ ] **Step 2: Run to verify it fails**

```bash
xcodebuild test -project "Claude Usage.xcodeproj" -scheme "Claude Usage" \
  -destination 'platform=macOS' \
  -only-testing:"Claude UsageTests/TokenStatsRefreshCoordinatorTests" 2>&1 | tail -20
```

Expected: **compile error** — `TokenStatsRefreshCoordinator` does not exist.

- [ ] **Step 3: Create the coordinator**

Create `Claude Usage/MenuBar/TokenStatsRefreshCoordinator.swift`:

```swift
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
/// megabytes twice a minute, so they get their own timer at `Constants.tokenStatsRefreshInterval`.
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
            withTimeInterval: Constants.tokenStatsRefreshInterval,
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
```

- [ ] **Step 4: Add the interval constant**

In `Claude Usage/Shared/Utilities/Constants.swift`, add at the top level of the `Constants` enum (next to the other timing values):

```swift
    /// Token stats are read from local JSONL, not the API, and a 30-day window walks hundreds of
    /// megabytes. They get a slower cadence than the 30-second usage refresh - deliberately more
    /// headroom than the scan currently needs, so the margin survives corpus growth.
    static let tokenStatsRefreshInterval: TimeInterval = 300
```

- [ ] **Step 5: Run the coordinator tests**

```bash
xcodebuild test -project "Claude Usage.xcodeproj" -scheme "Claude Usage" \
  -destination 'platform=macOS' \
  -only-testing:"Claude UsageTests/TokenStatsRefreshCoordinatorTests" 2>&1 | grep -E "Test case .* (passed|failed)|TEST (SUCCEEDED|FAILED)"
```

Expected: `** TEST SUCCEEDED **`, 5 test cases passing.

- [ ] **Step 6: Commit**

```bash
git add "Claude Usage/MenuBar/TokenStatsRefreshCoordinator.swift" \
        "Claude Usage/Shared/Utilities/Constants.swift" \
        "Claude UsageTests/TokenStatsRefreshCoordinatorTests.swift"
git commit -m "feat(tokens): dedicated 300s refresh coordinator with overlap guard"
```

---

## Task 6: Move `MenuBarManager` onto the coordinator

> **Execution order:** this task runs **after Task 7**, not before it. Task 7 adds
> `MenuBarIconConfiguration.countCacheTokens`, which this task reads; doing Task 6 first would
> leave a commit that does not compile. Task 7 has no dependency on this task, so the swap costs
> nothing and every commit stays buildable.

**Files:**
- Modify: `Claude Usage/MenuBar/MenuBarManager.swift:1445-1456` (remove inline load), plus lifecycle wiring

**Interfaces:**
- Consumes: `TokenStatsRefreshCoordinator`, `TokenStatsInputProviding`, `TokenStatsRefreshCoordinatorDelegate` from Task 5; `MenuBarIconConfiguration.countCacheTokens` from Task 7
- Produces: nothing new; `MenuBarManager.tokenStats` keeps its existing type and role.

- [ ] **Step 1: Remove the inline load from the usage refresh**

Delete this block from `MenuBarManager.swift` (currently lines 1445-1456):

```swift
            // Load Claude Code token stats (local files, not a network call).
            // Only the enabled frames are computed, to bound the JSONL scan.
            let enabledTokenFrames: Set<MenuBarMetricType> = await MainActor.run {
                let cfg = self.profileManager.activeProfile?.iconConfig ?? .default
                return Set(cfg.enabledMetrics.map { $0.metricType }.filter { $0.isTokenMetric })
            }
            let loadedTokenStats = enabledTokenFrames.isEmpty
                ? TokenStats.unavailable
                : self.tokenStatsService.load(enabledFrames: enabledTokenFrames)
            await MainActor.run {
                self.tokenStats = loadedTokenStats
            }
```

- [ ] **Step 2: Add the coordinator property**

Next to the existing `tokenStatsService` property declaration, add:

```swift
    private lazy var tokenStatsCoordinator: TokenStatsRefreshCoordinator = {
        let coordinator = TokenStatsRefreshCoordinator()
        coordinator.delegate = self
        coordinator.input = self
        return coordinator
    }()
```

If `tokenStatsService` is now unused, delete that property too — the coordinator owns the service.

- [ ] **Step 3: Conform to both protocols**

Add at the end of `MenuBarManager.swift`, outside the class body:

```swift
// MARK: - Token stats refresh

// `TokenStatsInputProviding` is read synchronously on the main thread by `refreshNow()`, so
// these accessors stay main-actor isolated like the rest of the class. If the compiler objects
// to the conformance, annotate the extension `@MainActor` rather than making the properties
// `nonisolated` - they read the active profile, which is main-actor state.
extension MenuBarManager: TokenStatsInputProviding {
    var enabledTokenFrames: Set<MenuBarMetricType> {
        let cfg = profileManager.activeProfile?.iconConfig ?? .default
        return Set(cfg.enabledMetrics.map { $0.metricType }.filter { $0.isTokenMetric })
    }

    var countCacheTokens: Bool {
        (profileManager.activeProfile?.iconConfig ?? .default).countCacheTokens
    }
}

extension MenuBarManager: TokenStatsRefreshCoordinatorDelegate {
    func tokenStatsCoordinator(_ coordinator: TokenStatsRefreshCoordinator, didLoad stats: TokenStats) {
        tokenStats = stats
    }
}
```

`MenuBarIconConfiguration.countCacheTokens` already exists at this point — Task 7 ran first. If it does not resolve, Task 7 was skipped; stop and complete it before continuing.

- [ ] **Step 4: Start and stop the coordinator with the manager**

Find where `refreshTimer` is first scheduled (around `MenuBarManager.swift:766`) and add immediately after that call:

```swift
        tokenStatsCoordinator.start()
```

Find the teardown that invalidates `refreshTimer` (around `MenuBarManager.swift:272`) and add:

```swift
        tokenStatsCoordinator.stop()
```

- [ ] **Step 5: Trigger an immediate refresh on user-initiated refresh and profile change**

In the method that handles a user-triggered refresh (the one that sets `lastRefreshTriggerTime`), add:

```swift
        tokenStatsCoordinator.refreshNow()
```

In the profile-change handler that reloads configuration, add the same line. This is what makes a toggle flip or a card being enabled show up without waiting out the 300-second interval.

- [ ] **Step 6: Build and run the full suite**

```bash
xcodebuild test -project "Claude Usage.xcodeproj" -scheme "Claude Usage" \
  -destination 'platform=macOS' 2>&1 | grep -cE "Test case .* failed"
```

Expected output: `0`. There are no unit tests for `MenuBarManager` itself — this step's job is to prove the wiring compiles and nothing else regressed.

- [ ] **Step 7: Commit**

```bash
git add "Claude Usage/MenuBar/MenuBarManager.swift"
git commit -m "refactor(menubar): move token stats onto their own coordinator

Drops the inline load from the 30-second usage refresh, which was
re-reading tens of megabytes of JSONL twice a minute even in
cache-inclusive mode."
```

---

# PHASE 3 — Toggle, UI, localization

## Task 7: `countCacheTokens` on `MenuBarIconConfiguration`

> **Execution order:** this task runs **before Task 6**. Task 6 reads the property added here, so
> doing it first keeps every commit buildable.

**Files:**
- Modify: `Claude Usage/Shared/Models/MenuBarIconConfig.swift:420-506`
- Create: `Claude UsageTests/MenuBarIconConfigTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `MenuBarIconConfiguration.countCacheTokens: Bool` (defaults `true`, decodes `true` when absent)

- [ ] **Step 1: Write the failing tests**

Create `Claude UsageTests/MenuBarIconConfigTests.swift`:

```swift
import XCTest
@testable import Claude_Usage

final class MenuBarIconConfigTests: XCTestCase {

    /// Profiles saved before this feature existed have no `countCacheTokens` key. They must
    /// decode as `true` so nobody's displayed numbers change on upgrade.
    func testDecodesMissingToggleAsTrue() throws {
        let legacy = """
        {
          "colorMode": "multiColor",
          "singleColorHex": "#00BFFF",
          "showIconNames": true,
          "showRemainingPercentage": false,
          "showTimeMarker": true,
          "showPaceMarker": false,
          "usePaceColoring": false,
          "metrics": []
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(MenuBarIconConfiguration.self, from: legacy)

        XCTAssertTrue(config.countCacheTokens)
    }

    func testDecodesExplicitFalse() throws {
        let json = """
        {
          "colorMode": "multiColor",
          "singleColorHex": "#00BFFF",
          "showIconNames": true,
          "showRemainingPercentage": false,
          "showTimeMarker": true,
          "showPaceMarker": false,
          "usePaceColoring": false,
          "countCacheTokens": false,
          "metrics": []
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(MenuBarIconConfiguration.self, from: json)

        XCTAssertFalse(config.countCacheTokens)
    }

    func testRoundTripsThroughEncoding() throws {
        var config = MenuBarIconConfiguration()
        config.countCacheTokens = false

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(MenuBarIconConfiguration.self, from: data)

        XCTAssertFalse(decoded.countCacheTokens, "the flag must survive a save/load cycle")
    }

    func testDefaultIsCacheInclusive() {
        XCTAssertTrue(MenuBarIconConfiguration().countCacheTokens)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
xcodebuild test -project "Claude Usage.xcodeproj" -scheme "Claude Usage" \
  -destination 'platform=macOS' \
  -only-testing:"Claude UsageTests/MenuBarIconConfigTests" 2>&1 | tail -20
```

Expected: **compile error** — `countCacheTokens` is not a member of `MenuBarIconConfiguration`.

- [ ] **Step 3: Add the property, init parameter, coding key, decode and encode**

In `MenuBarIconConfig.swift`, add the stored property after `usePaceColoring` (line 427):

```swift
    /// When true, the Total Tokens metrics report what `claude` reports: input + output +
    /// cache read + cache creation. When false, only input + output.
    var countCacheTokens: Bool
```

Add the init parameter after `usePaceColoring: Bool = true,`:

```swift
        countCacheTokens: Bool = true,
```

and its assignment after `self.usePaceColoring = usePaceColoring`:

```swift
        self.countCacheTokens = countCacheTokens
```

Add to `CodingKeys` after `case usePaceColoring`:

```swift
        case countCacheTokens
```

Add to `init(from:)` after the `usePaceColoring` line:

```swift
        // Absent for every profile saved before this feature; default true keeps existing
        // numbers identical on upgrade.
        countCacheTokens = try container.decodeIfPresent(Bool.self, forKey: .countCacheTokens) ?? true
```

Add to `encode(to:)` after the `usePaceColoring` line:

```swift
        try container.encode(countCacheTokens, forKey: .countCacheTokens)
```

- [ ] **Step 4: Run the config tests and the full suite**

```bash
xcodebuild test -project "Claude Usage.xcodeproj" -scheme "Claude Usage" \
  -destination 'platform=macOS' \
  -only-testing:"Claude UsageTests/MenuBarIconConfigTests" 2>&1 | grep -E "Test case .* (passed|failed)|TEST (SUCCEEDED|FAILED)"
```

Expected: `** TEST SUCCEEDED **`, 4 passing.

```bash
xcodebuild test -project "Claude Usage.xcodeproj" -scheme "Claude Usage" \
  -destination 'platform=macOS' 2>&1 | grep -cE "Test case .* failed"
```

Expected output: `0`.

- [ ] **Step 5: Commit**

```bash
git add "Claude Usage/Shared/Models/MenuBarIconConfig.swift" \
        "Claude UsageTests/MenuBarIconConfigTests.swift"
git commit -m "feat(config): add countCacheTokens toggle, defaulting to true"
```

---

## Task 8: Settings toggle and localization

**Files:**
- Modify: `Claude Usage/Views/Settings/Profile/AppearanceSettingsView.swift:228-229`
- Modify: `Claude Usage/Shared/Models/MenuBarIconConfig.swift:63-69` (neutral descriptions)
- Modify: all 14 `Claude Usage/Resources/*.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `MenuBarIconConfiguration.countCacheTokens` from Task 7
- Produces: string keys `appearance.count_cache_tokens_title`, `appearance.count_cache_tokens_description`

- [ ] **Step 1: Add both keys to all 14 locale files**

Run this to append the English text everywhere, then translate Vietnamese in the next step:

```bash
cd "/Users/mac/Github/haitranwang/self/Claude-Usage-Tracker/Claude Usage/Resources"
for d in *.lproj; do
  printf '\n"appearance.count_cache_tokens_title" = "Count cache tokens";\n"appearance.count_cache_tokens_description" = "Matches `claude` stats. Turn off to count only input + output tokens.";\n' >> "$d/Localizable.strings"
done
grep -c "count_cache_tokens" */Localizable.strings
```

Expected: every one of the 14 files reports `2`.

- [ ] **Step 2: Replace the Vietnamese strings with real translations**

In `Claude Usage/Resources/vi.lproj/Localizable.strings`, replace the two lines just appended with:

```
"appearance.count_cache_tokens_title" = "Tính cả token cache";
"appearance.count_cache_tokens_description" = "Khớp với số liệu của `claude`. Tắt để chỉ tính token input + output.";
```

- [ ] **Step 3: Add the toggle to the Appearance view**

In `AppearanceSettingsView.swift`, immediately after the closing brace of the Total Tokens - 30 Days block (line 228) and before the closing brace of the `VStack` (line 229), insert:

```swift

                        Divider()
                            .padding(.vertical, DesignTokens.Spacing.small)

                        SettingToggle(
                            title: "appearance.count_cache_tokens_title".localized,
                            description: "appearance.count_cache_tokens_description".localized,
                            isOn: Binding(
                                get: { configuration.countCacheTokens },
                                set: { newValue in
                                    configuration.countCacheTokens = newValue
                                    saveConfiguration()
                                }
                            )
                        )
```

- [ ] **Step 4: Make the metric descriptions neutral**

In `MenuBarIconConfig.swift`, replace the three token cases in the `description` computed property (lines 63-68):

```swift
        case .tokensAllTime:
            return "Claude Code lifetime tokens (input+output)"
        case .tokens7Days:
            return "Claude Code tokens, last 7 days"
        case .tokens30Days:
            return "Claude Code tokens, last 30 days"
```

with:

```swift
        // No claim about which token kinds are counted - that depends on the Count cache
        // tokens toggle, and `description` has no access to profile config.
        case .tokensAllTime:
            return "Claude Code lifetime tokens"
        case .tokens7Days:
            return "Claude Code tokens, last 7 days"
        case .tokens30Days:
            return "Claude Code tokens, last 30 days"
```

- [ ] **Step 5: Build and run the full suite**

```bash
xcodebuild test -project "Claude Usage.xcodeproj" -scheme "Claude Usage" \
  -destination 'platform=macOS' 2>&1 | grep -cE "Test case .* failed"
```

Expected output: `0`

- [ ] **Step 6: Verify the toggle end to end in the running app**

```bash
xcodebuild -project "Claude Usage.xcodeproj" -scheme "Claude Usage" \
  -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -3
open "$(xcodebuild -project "Claude Usage.xcodeproj" -scheme "Claude Usage" \
  -configuration Debug -showBuildSettings 2>/dev/null \
  | awk '/ BUILT_PRODUCTS_DIR/{d=$3} /FULL_PRODUCT_NAME/{n=$3} END{print d"/"n}')"
```

Then, by hand: open Settings → Appearance, enable the **7D** card, confirm a number appears in the menu bar, flip **Count cache tokens** off, and confirm the number drops by roughly two orders of magnitude within a second or two. Flip it back on and confirm it returns. If the number does not change until much later, Task 6 Step 5's `refreshNow()` wiring is missing.

- [ ] **Step 7: Commit**

```bash
git add "Claude Usage/Views/Settings/Profile/AppearanceSettingsView.swift" \
        "Claude Usage/Shared/Models/MenuBarIconConfig.swift" \
        "Claude Usage/Resources"
git commit -m "feat(settings): Count cache tokens toggle in Appearance

Adds the toggle under the Total Tokens cards in all 14 locales, and
drops the now-false '(input+output)' claim from the metric description."
```

---

## Final verification

- [ ] **Full suite green**

```bash
cd "/Users/mac/Github/haitranwang/self/Claude-Usage-Tracker"
xcodebuild test -project "Claude Usage.xcodeproj" -scheme "Claude Usage" \
  -destination 'platform=macOS' 2>&1 | grep -E "\*\* TEST (SUCCEEDED|FAILED)|Test case .* failed"
```

Expected: `** TEST SUCCEEDED **` and no failure lines.

- [ ] **The 10 original tests were never edited**

```bash
git diff main --stat -- "Claude UsageTests/TokenStatsServiceTests.swift"
```

Expected: no output. Any diff here means the regression net was cut and phases 0-1 are unverified.

- [ ] **Sanity-check the real numbers**

With the app running and all three cards enabled, cache-inclusive figures should be within a few percent of `claude`'s own stats view, and `ALL >= 30D >= 7D` must hold in both modes. Cache-exclusive 7D should land in the tens of millions, not billions.
