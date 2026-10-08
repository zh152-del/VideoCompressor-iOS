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

final class FormattersSizeChangeTests: XCTestCase {
    /// 31.4 MB → 62.6 MB：必须显示「体积增加 99.4%」，绝不能显示「约 0.0%」
    func testBiggerOutputShowsIncrease() {
        let t = Formatters.sizeChangeText(original: 31_400_000, compressed: 62_600_000)
        XCTAssertTrue(t.contains("99.4%"), "实际: \(t)")
        XCTAssertTrue(t.contains("体积增加"))
        XCTAssertFalse(t.contains("0.0%"))
    }

    /// 31.4 MB → 20 MB：节省 36.3%
    func testSmallerOutputShowsSaving() {
        let t = Formatters.sizeChangeText(original: 31_400_000, compressed: 20_000_000)
        XCTAssertTrue(t.contains("36.3%"), "实际: \(t)")
        XCTAssertTrue(t.contains("节省"))
    }

    /// 100 MB → 40 MB：节省 60%
    func testSixtyPercentSaving() {
        let t = Formatters.sizeChangeText(original: 100_000_000, compressed: 40_000_000)
        XCTAssertTrue(t.contains("60.0%"), "实际: \(t)")
    }
}
