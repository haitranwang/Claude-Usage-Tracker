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
| Cost of scanning JSONL every refresh? | Accepted, mitigated by a slower dedicated cadence |
| 30D is missing ~5/30 days of data | Show it plainly, no marker on the menu bar |
| Persistent app-side ledger? | **No** — rejected as not worth the complexity |

## Constraints discovered (measured, not assumed)

Scan cost on this machine, mirroring `TokenStatsService.scanJSONL` exactly (Swift, `-O`):

| Window | Time | Bytes read | Files |
|---|---|---|---|
| 1 day | 2.07s | 46.7 MB | 36 |
| 7 days | 6.47s | 140.8 MB | 335 |
| 30 days | 15.99s | 342.3 MB | 1,174 |

These grow with usage; they are a floor, not a ceiling.

**Neither data source is authoritative.** Comparing JSONL against `stats-cache.json` per day:

| Day | JSONL (io+cache) | stats-cache | Ratio |
|---|---|---|---|
| 08-08 | 557,858,334 | 464,650,349 | 120% |
| 08-07 | 422,917,895 | 516,125,880 | 82% |
| 08-03 | 1,069,226,587 | 866,840,041 | 123% |
| 08-02 | 6,332,559 | 371,372,939 | 2% |
| 07-15 | 29,273,398 | 101,551,147 | 29% |

Two independent causes, in opposite directions:

- **JSONL under-reports old days** — Claude Code's retention cleanup (`cleanupPeriodDays`,
  default 30) deletes session logs. Oldest surviving file here is 2026-07-13; a 30-day window
  needs 2026-07-12.
- **stats-cache under-reports recent days** — the CLI computes incrementally and advances
  `lastComputedDate`; a day computed mid-way never gets its remainder merged, so JSONL can exceed
  it by 20%+.

Consequence: "matching the CLI" is the goal, not absolute accuracy. No available number is exact.

## Design

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

Accepted asymmetry: with cache off, ALL comes from `modelUsage` while the windows come purely from
JSONL. On days whose JSONL was deleted, the windows under-count and ALL does not. This preserves
`ALL >= 30D >= 7D` and is the more accurate arrangement available.

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

`isLoading` is load-bearing, not defensive padding: at 16s and growing, a 30D scan will eventually
outlast its own interval, and overlapping scans each hold hundreds of MB.

This also fixes an existing performance bug: even in cache-inclusive mode today, the delta scan
covers every day after `lastComputedDate` — currently 36 files / 46.7 MB / 2.07s **every 30
seconds**. Moving to a 5-minute cadence cuts that tenfold for the shipped mode too.

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

Because the menu bar carries no marker for 30D's missing days, the caveat lives in the 30D
description string, where it appears in Settings only:

> 30 Days — Claude Code tokens, last 30 days. With cache off, older days may be missing because
> Claude Code deletes its own JSONL logs.

### 4. Testing

The highest-value test covers the easiest mistake: with cache off, JSONL lines **on or before**
`lastComputedDate` must be **counted** — the exact opposite of cache-inclusive mode, where they are
skipped as already folded into `dailyModelTokens`. An implementation that reuses the existing
filter silently under-counts most of the window, and no current test catches it.

| Test | Asserts |
|---|---|
| `exclusiveWindowCountsDaysBeforeCutoff` | 7D with cache off counts days ≤ cutoff from JSONL |
| `exclusiveModeExcludesCacheTokens` | a pure cache-read line (io = 0) contributes 0 |
| `exclusiveAllTimeUsesModelUsageIO` | ALL sums `inputTokens + outputTokens` only |
| `inclusiveModeUnchanged` | the 10 existing tests pass with expectations untouched |
| `configDecodesMissingToggleAsTrue` | legacy profile JSON yields `countCacheTokens == true` |
| `coordinatorSkipsTickWhileScanning` | `isLoading` prevents overlapping scans |

The 10 existing `TokenStatsServiceTests` must not be edited — they are the safety net proving
cache-inclusive behavior is untouched.

Timers are not tested directly (time-based tests are flaky). `refresh()` is separately callable so
the re-entrancy guard is testable; the thin `Timer` wiring is left uncovered.

## Explicitly out of scope

- **Persistent app-side daily ledger.** Would make 30D exact going forward and cut refresh to
  milliseconds by tail-reading appended bytes, and would preserve history the CLI deletes.
  Rejected: not worth the durable state. Revisit if the 5-minute scan becomes painful or 30D
  accuracy starts to matter.
- **Separate metric cards per mode** (6 cards). Rejected in favor of one toggle.
- **Configurable token refresh interval.** Fixed 300s constant.
- **Any marker on the menu bar for approximate 30D.** Deliberately declined.

## Known limitation, accepted

With cache off, 30D under-reports by roughly 5 days out of 30 today, and worsens as retention
cleanup runs. It is displayed without qualification on the menu bar by choice. The Settings
description is the only place this is disclosed.
