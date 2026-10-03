import XCTest
@testable import PapericoCore

private extension Data {
    mutating func append16(_ value: UInt16) { append(UInt8(value & 0xFF)); append(UInt8(value >> 8)) }
    mutating func append32(_ value: UInt32) { append16(UInt16(value & 0xFFFF)); append16(UInt16(value >> 16)) }
}

final class ZipArchiveTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    /// Synthetic ZIP of "hello"; uses both standard stored and raw-deflate payloads.
    private func fixture(name: String = "images/test.txt", deflated: Bool = false, checksum: UInt32 = 0x3610_A686) -> Data {
        let path = Data(name.utf8)
        let payload = deflated ? Data([0xCB, 0x48, 0xCD, 0xC9, 0xC9, 0x07, 0x00]) : Data("hello".utf8)
        let method: UInt16 = deflated ? 8 : 0
        var archive = Data()
        archive.append32(0x0403_4B50); archive.append16(20); archive.append16(0); archive.append16(method)
        archive.append32(0); archive.append32(checksum); archive.append32(UInt32(payload.count)); archive.append32(5)
        archive.append16(UInt16(path.count)); archive.append16(0); archive.append(path); archive.append(payload)
        let centralOffset = archive.count
        archive.append32(0x0201_4B50); archive.append16(20); archive.append16(20); archive.append16(0); archive.append16(method)
        archive.append32(0); archive.append32(checksum); archive.append32(UInt32(payload.count)); archive.append32(5)
        archive.append16(UInt16(path.count)); archive.append16(0); archive.append16(0); archive.append16(0); archive.append16(0)
        archive.append32(0); archive.append32(0); archive.append(path)
        let centralSize = archive.count - centralOffset
        archive.append32(0x0605_4B50); archive.append16(0); archive.append16(0); archive.append16(1); archive.append16(1)
        archive.append32(UInt32(centralSize)); archive.append32(UInt32(centralOffset)); archive.append16(0)
        return archive
    }

    func testStoredAndDeflatedResultsExtract() throws {
        for deflated in [false, true] {
            try ZipArchive.extract(data: fixture(deflated: deflated), to: root)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("images/test.txt"), encoding: .utf8), "hello")
        }
    }

    func testEveryTruncatedPrefixThrowsWithoutCrashing() {
        let archive = fixture()
        for count in 0..<archive.count {
            XCTAssertThrowsError(try ZipArchive.extract(data: Data(archive.prefix(count)), to: root), "Prefix \(count)")
        }
    }

    func testTraversalAndAbsolutePathsAreRejected() {
        for path in ["../escape", "/tmp/escape", "a/../../escape", "a\\..\\escape"] {
            XCTAssertThrowsError(try ZipArchive.extract(data: fixture(name: path), to: root))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testExistingSymlinkCannotEscapeDestination() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("images"), withDestinationURL: outside)
        XCTAssertThrowsError(try ZipArchive.extract(data: fixture(), to: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("test.txt").path))
    }

    func testChecksumMismatchIsRejected() {
        XCTAssertThrowsError(try ZipArchive.extract(data: fixture(checksum: 0), to: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("images/test.txt").path))
    }

    func testCentralDirectoryNameBoundsAreChecked() {
        var archive = fixture()
        let offset = 30 + "images/test.txt".utf8.count + 5
        archive[offset + 28] = 0xFF; archive[offset + 29] = 0xFF
        XCTAssertThrowsError(try ZipArchive.extract(data: archive, to: root))
    }
}
