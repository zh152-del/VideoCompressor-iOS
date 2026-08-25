import XCTest
@testable import VideoCompressor

final class FormattersTests: XCTestCase {
    func testBytes() {
        let s = Formatters.bytes(1024)
        XCTAssertFalse(s.isEmpty)
    }

    func testTime() {
        XCTAssertEqual(Formatters.time(0), "0:00")
        XCTAssertEqual(Formatters.time(65), "1:05")
        XCTAssertEqual(Formatters.time(3661), "1:01:01")
    }

    func testPercent() {
        XCTAssertEqual(Formatters.percent(0.5), "50%")
        XCTAssertEqual(Formatters.percent(1.2), "100%")
    }

    func testSavedPercent() {
        let s = Formatters.savedPercent(0.696)
        XCTAssertTrue(s.contains("69.6%"))
    }
}
