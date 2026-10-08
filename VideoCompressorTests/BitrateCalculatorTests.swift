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

final class BitrateCalculatorTargetTests: XCTestCase {
    /// 低码率源：31MB / 8分钟 ≈ 0.52Mbps，任何模式都无法有效压缩 → 返回 nil（跳过编码）
    func testLowBitrateSourceReturnsNil() {
        let bytes: Int64 = 31_400_000
        let duration: Double = 480
        let r = BitrateCalculator.targetVideoBitrate(sourceBytes: bytes, durationSeconds: duration,
                                                     height: 1080, fps: 30, factor: 0.55)
        XCTAssertNil(r, "低码率源不应再重编码")
    }

    /// 高码率源：428MB / 32s ≈ 107Mbps，平衡模式应显著低于源码率
    func testHighBitrateSourceGetsCompressed() {
        let bytes: Int64 = 428_000_000
        let duration: Double = 32
        let r = BitrateCalculator.targetVideoBitrate(sourceBytes: bytes, durationSeconds: duration,
                                                     height: 1080, fps: 30, factor: 0.55)
        XCTAssertNotNil(r)
        let bps = r!
        XCTAssertLessThan(bps, 60_000_000, "目标码率必须低于源")
        // 且被参考码率上限约束（1080p 参考码率 8Mbps）
        XCTAssertLessThanOrEqual(bps, 8_000_000)
    }

    /// 系数排序：quick > balanced > high
    func testFactorOrdering() {
        let a = BitrateCalculator.factor(for: .quick)
        let b = BitrateCalculator.factor(for: .balanced)
        let c = BitrateCalculator.factor(for: .high)
        XCTAssertGreaterThan(a, b)
        XCTAssertGreaterThan(b, c)
    }

    /// estimateOutputBytes：低码率源返回 nil（预计无法压缩）
    func testEstimateNoGainForLowBitrate() {
        let est = BitrateCalculator.estimateOutputBytes(fileSizeBytes: 7_700_000, durationSeconds: 300,
                                                        height: 1080, fps: 30, mode: .balanced)
        XCTAssertNil(est)
    }
}
