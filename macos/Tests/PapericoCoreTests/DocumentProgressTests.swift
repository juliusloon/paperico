import XCTest
@testable import PapericoCore

final class DocumentProgressTests: XCTestCase {
    func testScrollingWithinOnePageAdvancesProgress() {
        let early = PDFReadingPosition(pageIndex: 3, fraction: 0.2)
        let late = PDFReadingPosition(pageIndex: 3, fraction: 0.8)
        XCTAssertEqual(early.percentage(pageCount: 10), 32, accuracy: 0.0001)
        XCTAssertEqual(late.percentage(pageCount: 10), 38, accuracy: 0.0001)
    }

    func testSavedFractionRestoresAcrossPageBoundaries() {
        for progress in [0.0, 0.1, 9.99, 10, 42.7, 99.9, 100] {
            let position = PDFReadingPosition(progress: progress, pageCount: 10)
            XCTAssertEqual(position.percentage(pageCount: 10), progress, accuracy: 0.0001)
        }
        let end = PDFReadingPosition(progress: 100, pageCount: 10)
        XCTAssertEqual(end.pageIndex, 9)
        XCTAssertEqual(end.fraction, 1)
    }

    func testInvalidPositionsAreClamped() {
        XCTAssertEqual(PDFReadingPosition(pageIndex: -2, fraction: -1).percentage(pageCount: 10), 0)
        XCTAssertEqual(PDFReadingPosition(pageIndex: 20, fraction: 2).percentage(pageCount: 10), 100)
        XCTAssertEqual(PDFReadingPosition(progress: .nan, pageCount: 10).percentage(pageCount: 10), 0)
        XCTAssertEqual(PDFReadingPosition(progress: 50, pageCount: 0).percentage(pageCount: 0), 0)
    }
}
