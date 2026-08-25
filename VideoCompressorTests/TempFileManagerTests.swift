import XCTest
@testable import VideoCompressor

final class TempFileManagerTests: XCTestCase {
    func testUniqueOutputURLs() {
        let m = TempFileManager.shared
        let a = m.newOutputURL()
        let b = m.newOutputURL()
        XCTAssertNotEqual(a.path, b.path)
    }

    func testRemoveCreatesThenDeletes() {
        let m = TempFileManager.shared
        let url = m.newOutputURL()
        try? "hello".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        m.remove(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
