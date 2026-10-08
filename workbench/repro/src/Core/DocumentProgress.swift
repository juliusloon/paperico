import Foundation

/// A continuous PDF position: page index plus the fraction passed on that page.
struct PDFReadingPosition: Equatable, Sendable {
    let pageIndex: Int
    let fraction: Double

    init(pageIndex: Int, fraction: Double) {
        self.pageIndex = max(0, pageIndex)
        self.fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0
    }

    init(progress: Double, pageCount: Int) {
        let value = progress.isFinite ? min(100, max(0, progress)) : 0
        let position = value / 100 * Double(max(0, pageCount))
        let index = min(max(0, pageCount - 1), Int(position))
        self.init(pageIndex: index, fraction: position - Double(index))
    }

    func percentage(pageCount: Int) -> Double {
        guard pageCount > 0 else { return 0 }
        return min(100, (Double(pageIndex) + fraction) / Double(pageCount) * 100)
    }
}
