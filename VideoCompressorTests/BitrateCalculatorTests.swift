import XCTest
@testable import VideoCompressor

final class BitrateCalculatorTests: XCTestCase {
    func testQualityBitrateScalesWithHeight() {
        let low = BitrateCalculator.bitrate(quality: 0.7, height: 480)
        let high = BitrateCalculator.bitrate(quality: 0.7, height: 1080)
        XCTAssertGreaterThan(high, low)
    }

    func testQualityClamped() {
        let clamped = BitrateCalculator.bitrate(quality: 1.2, height: 1080)
        let over = BitrateCalculator.bitrate(quality: 5.0, height: 1080)
        XCTAssertEqual(clamped, over)
    }

    func testTargetSizeBitrate() {
        // 100MB / 60s，预留音频后约 13.1 Mbps
        let bps = BitrateCalculator.bitrate(targetBytes: 100_000_000, durationSeconds: 60)
        XCTAssertGreaterThan(bps, 10_000_000)
        XCTAssertLessThan(bps, 16_000_000)
    }

    func testTargetSizeZeroDuration() {
        let bps = BitrateCalculator.bitrate(targetBytes: 100_000_000, durationSeconds: 0)
        XCTAssertEqual(bps, 2_000_000)
    }
}
