# Cache-exclusive token mode — design

**Date:** 2026-08-10
**Status:** Approved, ready for implementation planning
**Branch:** `local/my-build` (personal build; not an upstream PR)

## Problem

Claude Code CLI 2.1.221 redefined `~/.claude/stats-cache.json`'s `dailyModelTokens.tokensByModel`
from `input + output` to `input + output + cache_read + cache_creation`, and added a
`dailyModelTokensVersion` field whose bump makes the CLI rebuild that history under the new
definition. The 7-day figure on this machine jumped from ~12M to ~2.9B overnight, retroactively.

The app now mirrors the CLI faithfully (fixed 2026-08-10, all frames cache-inclusive). But cache
reads are ~95% of that total and bill at a fraction of input tokens, so the number answers
"how many tokens moved" rather than "how much did I actually use". This design adds a second mode
that answers the latter.

## Decisions

| Question | Decision |
|---|---|
| How are the two modes exposed? | One global toggle; the three cards keep their meaning slots |
| Cost of scanning JSONL every refresh? | Cut ~15x by a byte-level rewrite, landed first, separately |
| Dedicated slower cadence for token stats? | Yes, 300s — now headroom rather than rescue |
| Persistent app-side ledger? | **No** — rejected as not worth the complexity |

## Constraints discovered (measured, not assumed)

Scan cost on this machine, mirroring `TokenStatsService.scanJSONL` exactly (Swift, `-O`):

| Window | Time | Bytes read | Files |
|---|---|---|---|
| 1 day | 2.1–2.6s | 47–61 MB | 36–77 |
| 7 days | 6.5–8.5s | 141–155 MB | 335–378 |
| 30 days | 16–20s | 342–356 MB | 1,174–1,216 |

Ranges, not points: the corpus grew measurably across a few hours of measurement. These are a
floor, not a ceiling.

**JSONL is the authoritative source; `stats-cache.json` is a cached projection of it.** Bucketing
JSONL lines by the UTC date prefix of `timestamp` — which is what both the CLI and this app do —
reproduces `dailyModelTokens` **exactly, to the token, on all 29 days where both have data**. Zero
days differ by more than 2%.

Coverage of the last 30 days:

| | Days |
|---|---|
| Both sources, byte-identical | 25 |
| JSONL only (today; CLI hasn't computed it yet) | 1 |
| Cache only (JSONL deleted) | **0** |
| No activity in either | 4 |

Retention cleanup has removed JSONL for only five days — 2026-06-09 through 06-18, all more than
52 days old and outside every window the app offers. Oldest surviving JSONL content is 2026-06-22,
i.e. ~49 days of history, comfortably more than the 30-day window needs.

> **Correction.** An earlier draft claimed the two sources disagreed by ±20% and that 30D was
> missing ~5/30 days. That was an analysis error: the comparison bucketed JSONL by local time
> (UTC+7) while both the CLI and the app bucket by UTC date. Re-run with UTC bucketing, the
> disagreement vanishes entirely. Cache-exclusive 30D is complete and exact — no caveat needed,
> and the decision to display it unqualified is simply correct rather than a compromise.

## Design

### 0. Prerequisite: byte-level scanner rewrite (ships first, separately)

Profiling the 7-day scan shows only **5% of the time is disk I/O**. The rest is Swift String and
Foundation overhead:

| Stage | Share | Problem |
|---|---|---|
| `contains("\"usage\"")` prefilter | **36.8%** | `String.contains` is grapheme-aware |
| `split(separator: "\n")` | **29.7%** | 57k Substrings; holds the whole 19.8 MB String |
| `DateFormatter` | **16.9%** | 31k parses |
| `JSONDecoder` + `.convertFromSnakeCase` | 10.9% | transforms every key of every object |
| read file | 5.0% | |
| enumerate + stat | 0.2% | |

The comment calling the prefilter "cheap … before paying for JSON decoding" is inverted: it costs
3.4x the decoding it exists to avoid. And the date handling is a round trip to nowhere —
`dayFromTimestamp` parses `"2026-08-10"` into a `Date` so that `dayKey` can format it back into
`"2026-08-10"`, through two `DateFormatter` calls. `"yyyy-MM-dd"` sorts lexicographically in
timestamp order, so plain string comparison replaces both.

Four changes, no behavior change:

1. `Data(contentsOf:options:.mappedIfSafe)` instead of `String(contentsOf:)`
2. split lines on byte `0x0A` and search the `"usage"` needle over UTF-8 bytes
3. compare `"yyyy-MM-dd"` prefixes as strings; delete per-line `DateFormatter` use
4. explicit `CodingKeys` instead of `.convertFromSnakeCase`

Measured on the same corpus, asserting identical per-day output:

| Window | Before | After | Speedup |
|---|---|---|---|
| 7 days | 8.46s | **0.55s** | 15.3x |
| 30 days | 20.01s | **2.84s** | 7.0x |

This lands as its own change with a test proving per-day output is unchanged, before any feature
work. It benefits the shipped cache-inclusive mode too.

Equivalence must be asserted on **completed days only** — today's JSONL is being appended to while
the test runs, so a naive before/after comparison races the writer and reports a phantom mismatch.

The static `DateFormatter` is also not thread-safe; removing per-line use of it clears the way for
parallelising the scan later, which is the obvious next lever if it is ever needed.

### 1. Semantics and data sources

The existing cache+delta hybrid **only works for the cache-inclusive mode**. With cache off,
`dailyModelTokens` is unusable (cache is baked in and cannot be subtracted back out) and
`lastComputedDate` stops being a meaningful boundary for windows. The two modes are therefore two
paths, not one path with a flag.

| Frame | Cache ON (current) | Cache OFF (new) |
|---|---|---|
| ALL | `modelUsage` (4 kinds) + JSONL after cutoff | `modelUsage` (**io only**) + JSONL **io** after cutoff |
| 7D | `dailyModelTokens` + JSONL after cutoff | JSONL **io**, full 7-day window, cutoff ignored |
| 30D | `dailyModelTokens` + JSONL after cutoff | JSONL **io**, full 30-day window, cutoff ignored |

ALL keeps its hybrid shape in both modes so it never lags behind 7D. When 7D or 30D is enabled,
ALL's "JSONL after cutoff" days are a subset of the window already being scanned — no second pass.

With cache off, ALL comes from `modelUsage` while the windows come purely from JSONL. Since JSONL
reproduces the cache exactly over the retained period, the two agree; the only divergence is
history older than JSONL retention (>49 days here), which ALL includes and the windows never
reach anyway. `ALL >= 30D >= 7D` holds.

Refactor `scanJSONL` to take an explicit range and token kind rather than threading a cutoff
through the loop:

```swift
enum TokenKind { case all, inputOutputOnly }   // .all adds cache_read + cache_creation

func scanJSONL(
    projectsDir: URL,
    range: ClosedRange<Date>,
    counting: TokenKind
) -> (daily: [String: Int], anyParsed: Bool)
```

`anyParsed` is retained as-is: availability still means "the cache decoded, or some JSONL file was
read", in both modes. An empty range must return `anyParsed == false` without touching disk.

Cache-inclusive passes `dayAfter(cutoff)...today`; cache-exclusive passes `windowStart...today`.
The per-line `day > cacheCutoff` filter disappears into the range, so each path reads on its own
without needing to hold the other in mind.

### 2. Scheduling

Token stats move out of the 30-second usage refresh into their own coordinator, following the
existing `UsageRefreshCoordinator` shape:

```
TokenStatsRefreshCoordinator
  ├── own Timer, 300s
  ├── delegate delivers TokenStats to MenuBarManager
  └── isLoading flag: a tick that lands mid-scan is skipped
```

Immediate recompute (not waiting for the next tick) on: app start, toggle change, token-card
enable/disable, and user-triggered manual refresh.

`isLoading` stays even though section 0 makes a 30D scan 2.84s: cost grows with the corpus, and an
overlapping pair of scans is a failure mode worth one boolean.

The 300s cadence is now **headroom, not rescue**. With the byte-level scanner, a 7-day scan costs
0.55s — running it every 30 seconds would be 1.8% duty cycle, already four times cheaper than what
the shipped cache-inclusive mode costs today (2.07s per 30s). 300s is chosen so the margin holds as
the corpus grows, not because the scan is expensive.

Moving off the 30-second loop also fixes an existing performance bug on its own: even in
cache-inclusive mode today, the delta scan covers every day after `lastComputedDate` — currently
36 files / 46.7 MB / 2.07s **every 30 seconds**.

Remove the inline load at `MenuBarManager.swift:1445-1456`. That file is 1,975 lines; extracting a
small focused type matches the structure already in place.

### 3. UI and state

Add `countCacheTokens: Bool = true` to `MenuBarIconConfiguration`, beside `showPaceMarker`. Decode
via `decodeIfPresent ?? true` so existing profiles keep current behavior — default stays
CLI-matching and nobody's numbers change on upgrade.

Stored per profile. Slightly odd (token data comes from `~/.claude` and is identical across
profiles) but the three token cards are already per-profile, so this is consistent and needs no new
plumbing. A truly global setting would require its own `DataStore` key; not worth it.

Appearance settings, directly under the Total Tokens cards:

```
Total Tokens
  [x] ALL     [x] 7D     [ ] 30D
  ─────────────────────────────────
  Count cache tokens              [ON]
  Matches `claude` stats. Turn off to
  count only input + output tokens.
```

**Localization.** The app uses bare `NSLocalizedString` with no fallback layer
(`LocalizationManager.swift:13-15`), so a key missing from a `.lproj` renders as the raw key
string. Both new strings must be added to all 14 locale files — Vietnamese properly translated,
the other 12 carrying the English text (readable, unlike a raw key).

**Existing wrong string.** `MenuBarMetricType.description` reads "Claude Code lifetime tokens
(input+output)" (`MenuBarIconConfig.swift:64`), which is false in cache-inclusive mode.

The three description strings become **neutral** — they drop any claim about which token kinds are
counted, and the toggle's own caption carries that explanation. They stay plain stored strings on
the enum, not mode-aware: `description` is a computed property on `MenuBarMetricType`, which has no
access to profile config, and threading config into it to vary one clause is not worth it.

No caveat string is needed for 30D. The earlier draft added one on the belief that 30D was missing
days; measurement showed it is complete (see the Correction above), so the description stays plain.

### 4. Testing

The highest-value test covers the easiest mistake: with cache off, JSONL lines **on or before**
`lastComputedDate` must be **counted** — the exact opposite of cache-inclusive mode, where they are
skipped as already folded into `dailyModelTokens`. An implementation that reuses the existing
filter silently under-counts most of the window, and no current test catches it.

| Test | Asserts | Phase |
|---|---|---|
| `byteScannerMatchesStringScanner` | identical per-day output, completed days only | 0 |
| `scannerHandlesFileWithoutTrailingNewline` | last line still counted when the file lacks `\n` | 0 |
| `scannerSkipsLinesWithoutUsage` | needle search does not misfire mid-token | 0 |
| `exclusiveWindowCountsDaysBeforeCutoff` | 7D with cache off counts days ≤ cutoff from JSONL | 1 |
| `exclusiveModeExcludesCacheTokens` | a pure cache-read line (io = 0) contributes 0 | 1 |
| `exclusiveAllTimeUsesModelUsageIO` | ALL sums `inputTokens + outputTokens` only | 1 |
| `inclusiveModeUnchanged` | the 10 existing tests pass with expectations untouched | 1 |
| `configDecodesMissingToggleAsTrue` | legacy profile JSON yields `countCacheTokens == true` | 3 |
| `coordinatorSkipsTickWhileScanning` | `isLoading` prevents overlapping scans | 2 |

The 10 existing `TokenStatsServiceTests` must not be edited — they are the safety net proving
cache-inclusive behavior is untouched, and they are what makes phase 0 safe to land on its own.

Phase 0's byte-level rewrite is where off-by-one bugs live: a file with no trailing newline, an
empty file, a line whose final byte is the closing brace. Those cases get explicit tests rather
than relying on the corpus happening to contain them.

Timers are not tested directly (time-based tests are flaky). `refresh()` is separately callable so
the re-entrancy guard is testable; the thin `Timer` wiring is left uncovered.

## Explicitly out of scope

- **Persistent app-side daily ledger.** Would cut refresh to milliseconds by tail-reading appended
  bytes and would preserve history past Claude Code's retention. Rejected: the byte-level rewrite
  already gets 7D to 0.55s without any durable state, which removes the motivation. Revisit only
  if the corpus grows enough to make even the fast scan painful.
- **Parallelising the scan across files.** Unnecessary at 0.55s. Phase 0 removes the shared
  `DateFormatter` that would have made it unsafe, so the door stays open.
- **Separate metric cards per mode** (6 cards). Rejected in favor of one toggle.
- **Configurable token refresh interval.** Fixed 300s constant.

## Known limitations, accepted

- **Scan cost grows with usage.** Every figure here is a floor; the corpus grew measurably during
  a few hours of measurement. The 300s cadence and `isLoading` guard exist to absorb that.
- **`mtime`-based file skipping can under-scan** if a file's modification time is reset by
  something other than the CLI. Pre-existing behavior, documented in the code, unchanged here.
- **History older than JSONL retention is only visible in ALL**, which reads `modelUsage`. The
  windows cannot reach back that far, but they never need to — retention here is ~49 days against
  a 30-day maximum window.
