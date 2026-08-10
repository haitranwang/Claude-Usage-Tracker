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
}
