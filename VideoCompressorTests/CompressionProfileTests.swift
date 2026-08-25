import XCTest
@testable import VideoCompressor

final class CompressionProfileTests: XCTestCase {
    func testDefaultProfile() {
        let p = CompressionProfile()
        XCTAssertEqual(p.mode, .balanced)
    }

    func testCustomSettingsEquatable() {
        let a = CustomSettings(resolution: .p1080, fps: 30, quality: 0.7, codec: .hevc, targetSizeMB: 50)
        let b = CustomSettings(resolution: .p1080, fps: 30, quality: 0.7, codec: .hevc, targetSizeMB: 50)
        XCTAssertEqual(a, b)
    }

    func testModeDisplayNames() {
        XCTAssertEqual(CompressionMode.quick.displayName, "快速压缩")
        XCTAssertEqual(CompressionMode.high.displayName, "高压缩")
    }

    func testResolutionTargetHeight() {
        XCTAssertNil(PresetResolution.original.targetHeight)
        XCTAssertEqual(PresetResolution.p1080.targetHeight, 1080)
    }

    func testCodecAvType() {
        XCTAssertEqual(VideoCodec.h264.avCodecType, "avc1")
        XCTAssertEqual(VideoCodec.hevc.avCodecType, "hvc1")
    }
}
