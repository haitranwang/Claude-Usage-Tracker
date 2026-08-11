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
        cal.timeZone = .gmt
        return cal
    }()

    private lazy var dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = .gmt
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
        //
        // Note: "not-a-real-timestamp" is rejected here only because ASCII 'n' sorts above the
        // digits in `toKey`, failing the upper-bound string comparison - not because the shape
        // check recognises it as a non-date. `testMalformedCalendarDayIsRejected` below covers
        // the shape check itself with an input the range compare alone would accept.
        let bad = """
        {"type":"assistant","timestamp":"not-a-real-timestamp","message":{"usage":{"input_tokens":999,"output_tokens":999}}}
        """
        let dir = writeRawJSONL(bad + "\n" + line(day(offsetFromToday: -1), input: 4, output: 1))
        XCTAssertEqual(allTime(dir), 5)
    }

    func testMalformedCalendarDayIsRejected() {
        // "2026-07-32" has no real calendar meaning, but its digits and dashes are shaped just
        // like a real day key, and it sorts within range of any window that spans July/August -
        // so without a shape+range check on month/day, its tokens would land under a key
        // `windowSum` can never enumerate (invisible to 7D/30D) while still inflating all-time.
        let bad = """
        {"type":"assistant","timestamp":"2026-07-32T12:00:00.000Z","message":{"usage":{"input_tokens":999,"output_tokens":999}}}
        """
        let dir = writeRawJSONL(bad + "\n" + line(day(offsetFromToday: -1), input: 4, output: 1))
        XCTAssertEqual(allTime(dir), 5)
    }

    func testInvalidUTF8ByteDoesNotDropTheWholeFile() {
        // Unlike the old strict-UTF-8 `String(contentsOf:encoding:.utf8)` read - which returned
        // nil, and dropped the entire file, if a single byte anywhere was invalid UTF-8 - the
        // memory-mapped `Data` read has no such validation. A file with one corrupted line must
        // still contribute its other, decodable lines.
        let projectsDir = tempDir.appendingPathComponent("projects/p")
        try! FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)

        var bytes = Data(line(day(offsetFromToday: -1), input: 10, output: 5).utf8)
        bytes.append(UInt8(ascii: "\n"))
        bytes.append(0xFF) // 0xFF is not valid UTF-8 at any position (not a continuation byte, which is 0x80-0xBF)
        bytes.append(UInt8(ascii: "\n"))
        bytes.append(Data(line(day(offsetFromToday: -1), input: 1, output: 2).utf8))

        let fileURL = projectsDir.appendingPathComponent("session.jsonl")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        try! bytes.write(to: fileURL)

        XCTAssertEqual(allTime(projectsDir.deletingLastPathComponent()), 18)
    }

    func testFileWithNoDecodableLineStillReportsAvailable() {
        // Under the old strict-UTF-8 `String(contentsOf:encoding:.utf8)` read, a file that
        // failed to decode was skipped entirely before `anyParsed` was set, so - with no
        // stats-cache.json present - `load` fell through to `.unavailable` and the menu-bar
        // metric hid itself rather than showing 0. The memory-mapped read has no such
        // all-or-nothing failure mode: the file opens successfully regardless of its bytes, so
        // `anyParsed` is set even when it contains no decodable line at all. Availability must
        // reflect that: the metric should show 0, not disappear.
        let projectsDir = tempDir.appendingPathComponent("projects/p")
        try! FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)

        let bytes = Data(repeating: 0xFF, count: 32)
        let fileURL = projectsDir.appendingPathComponent("session.jsonl")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        try! bytes.write(to: fileURL)

        let stats = TokenStatsService().load(
            enabledFrames: [.tokensAllTime],
            statsURL: tempDir.appendingPathComponent("no-such-cache.json"),
            projectsDir: projectsDir.deletingLastPathComponent(),
            referenceDate: referenceDate
        )

        XCTAssertTrue(stats.isAvailable)
        XCTAssertEqual(stats.allTime, 0)
    }

    // MARK: - Timezone regression

    /// Pins day bucketing to UTC. JSONL `timestamp` fields are UTC instants and the `claude` CLI
    /// buckets `dailyModelTokens` by the UTC calendar day (verified against the real corpus:
    /// summing both ways, only UTC matched `stats-cache.json` on every day - local was off by
    /// ~20%). This service's day arithmetic - `today`, window bounds, the day-key comparisons -
    /// must therefore all be done in UTC too, or a local-timezone `today` gets compared against
    /// UTC-keyed data.
    ///
    /// `referenceDate` is a fixed instant, 2026-08-10T20:00:00Z, chosen because its UTC calendar
    /// day (2026-08-10) and its local calendar day at UTC+7 (2026-08-11, since 20:00 UTC + 7h
    /// rolls to 03:00 the next day) disagree - this is exactly the skew the bug produced on a
    /// UTC+7 machine every night between 00:00 and 07:00 local. A `Date()` reference would not
    /// discriminate: most hours of most days the UTC and local dates coincide, so a reverted,
    /// local-timezone service would pass this test as often as it fails it depending on when it
    /// happened to run.
    ///
    /// The expected day strings are hardcoded UTC literals rather than computed via this test's
    /// own calendar/formatter, so a shared bug in both the service and the fixture-generation
    /// code can't cancel out and hide a real regression - the literals encode what the *correct*
    /// window is, independent of how the service (or this file's helpers) compute it.
    ///
    /// With a correct UTC service, the 7-day window ending on 2026-08-10 (UTC) is
    /// 2026-08-04...2026-08-10 inclusive. A line dated 2026-08-04 (the oldest in-window day) must
    /// count; a line dated 2026-08-03 (one day older) must not. Under the pre-fix local-timezone
    /// bug at UTC+7, `today` would resolve to the local date 2026-08-11, shifting the window to
    /// 2026-08-05...2026-08-11 and silently dropping the 2026-08-04 line - exactly the undercount
    /// this test exists to catch.
    func testSevenDayWindowUsesUTCCalendarDayNotLocal() {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = .gmt
        let referenceDate = utcCalendar.date(from: DateComponents(
            year: 2026, month: 8, day: 10, hour: 20, minute: 0, second: 0
        ))!

        let dir = writeRawJSONL(
            line("2026-08-04", input: 100, output: 1) + "\n"
            + line("2026-08-03", input: 999_999, output: 999_999)
        )

        let stats = TokenStatsService().load(
            enabledFrames: [.tokens7Days],
            statsURL: tempDir.appendingPathComponent("no-such-cache.json"),
            projectsDir: dir,
            referenceDate: referenceDate
        )

        XCTAssertTrue(stats.isAvailable)
        XCTAssertEqual(
            stats.last7Days, 101,
            "2026-08-04 is the oldest day in the UTC 7-day window ending 2026-08-10 and must "
            + "count; 2026-08-03 is one day outside it and must not, even though referenceDate's "
            + "local date at UTC+7 is 2026-08-11, which under the old local-timezone bug would "
            + "shift the window to 2026-08-05...2026-08-11 and drop the 2026-08-04 line"
        )
    }
}
