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
        XCTAssertEqual(
            stats.allTime, 6013,
            """
            6000 modelUsage io + 13 from the one post-cutoff JSONL day (day -1). The pre-cutoff \
            day (-20, 120 io) and the on-cutoff-adjacent day (-3, 37 io) must NOT be added again: \
            modelUsage already contains them, so double-counting would put allTime at 6170.
            """
        )
        XCTAssertGreaterThanOrEqual(stats.last30Days, stats.last7Days)
        XCTAssertGreaterThanOrEqual(stats.allTime, stats.last7Days)
    }

    func testExclusiveOrderingHoldsWithSelfConsistentCache() {
        // Finding 3: exclusive mode's allTime (from modelUsage) and its windows (from JSONL) come
        // from two independent sources, so allTime >= last30Days >= last7Days only holds because
        // a self-consistent cache's modelUsage lifetime total already covers every pre-cutoff day
        // still on disk. Build exactly that here: modelUsage io (300) comfortably covers the
        // pre-cutoff days present in the fixture (120 + 37 = 157), the way a cache the CLI itself
        // wrote always would.
        let cutoff = day(offsetFromToday: -2)
        let statsURL = writeStatsCache("""
        {
          "modelUsage": { "m": { "inputTokens": 250, "outputTokens": 50,
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
        XCTAssertEqual(stats.allTime, 313, "300 modelUsage io + 13 from the one post-cutoff day")
        XCTAssertGreaterThanOrEqual(stats.allTime, stats.last30Days)
        XCTAssertGreaterThanOrEqual(stats.last30Days, stats.last7Days)
    }

    func testExclusiveWindowUnavailableWhenProjectsDirHasNoJSONL() {
        // Finding 2: with only a window frame enabled, a valid stats cache cannot vouch for it -
        // the window comes entirely from JSONL in exclusive mode. A fresh install or a projects
        // directory pruned of session files must report unavailable rather than a confident 0.
        let cutoff = day(offsetFromToday: -2)
        let statsURL = writeStatsCache("""
        { "modelUsage": {}, "dailyModelTokens": [], "lastComputedDate": "\(cutoff)" }
        """)
        let emptyProjectsDir = tempDir.appendingPathComponent("projects-empty")
        try! FileManager.default.createDirectory(at: emptyProjectsDir, withIntermediateDirectories: true)

        let stats = load([.tokens7Days], statsURL: statsURL, projectsDir: emptyProjectsDir)

        XCTAssertFalse(stats.isAvailable, "no JSONL exists to back the 7D window, so the cache can't vouch for it")
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
