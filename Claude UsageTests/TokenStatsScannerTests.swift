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
