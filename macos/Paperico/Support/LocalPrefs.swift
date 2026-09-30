import Foundation

/// UserDefaults persistence with the same keys the web app uses in localStorage.
enum LocalPrefs {
    private static let d = UserDefaults.standard

    // MARK: workspace nav

    static var lastPaperId: String? {
        get { d.string(forKey: "paperico:last-paper") }
        set { d.set(newValue ?? "", forKey: "paperico:last-paper") }
    }

    // MARK: reader shell widths

    static var leftWidth: CGFloat {
        get { CGFloat(d.double(forKey: "paperico:left-width")) }
        set { d.set(Double(newValue), forKey: "paperico:left-width") }
    }

    static var rightWidth: CGFloat {
        get { CGFloat(d.double(forKey: "paperico:right-width")) }
        set { d.set(Double(newValue), forKey: "paperico:right-width") }
    }

    // MARK: per-paper reader state

    static func readerMode(paperId: String) -> String {
        d.string(forKey: "paperico:reader-mode:\(paperId)") ?? "text"
    }

    static func setReaderMode(_ mode: String, paperId: String) {
        d.set(mode, forKey: "paperico:reader-mode:\(paperId)")
    }

    static func textProgress(paperId: String) -> Double {
        d.double(forKey: "paperico:text-progress:\(paperId)")
    }

    static func setTextProgress(_ value: Double, paperId: String) {
        d.set(value, forKey: "paperico:text-progress:\(paperId)")
    }

    static func pdfProgress(paperId: String) -> Double {
        d.double(forKey: "paperico:pdf-progress:\(paperId)")
    }

    static func setPdfProgress(_ value: Double, paperId: String) {
        d.set(value, forKey: "paperico:pdf-progress:\(paperId)")
    }

    static func pdfZoom(paperId: String) -> Double {
        let stored = d.double(forKey: "paperico:pdf-zoom:\(paperId)")
        return stored > 0 ? stored : 1
    }

    static func setPdfZoom(_ value: Double, paperId: String) {
        d.set(value, forKey: "paperico:pdf-zoom:\(paperId)")
    }
}
