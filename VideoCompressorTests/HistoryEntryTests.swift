import XCTest
@testable import VideoCompressor

final class HistoryEntryTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let entry = HistoryEntry(
            id: UUID(),
            name: "t",
            originalBytes: 1000,
            compressedBytes: 300,
            savedBytes: 700,
            date: Date(),
            mode: "平衡压缩",
            sourceResolution: "1920×1080",
            outputResolution: "1280×720",
            sourceCodec: "H.264",
            outputCodec: "HEVC",
            durationSeconds: 12,
            savedAssetLocalIdentifier: nil
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: data)
        XCTAssertEqual(decoded.name, "t")
        XCTAssertEqual(decoded.compressionRatio, 0.7, accuracy: 0.0001)
    }
}
