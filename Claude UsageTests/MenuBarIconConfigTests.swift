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
