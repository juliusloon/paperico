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

    // MARK: appearance(纯客户端设置)

    /// 外观三存于 UserDefaults:修改即时生效,不依赖本机数据服务是否启动。
    /// 后端 /api/settings 里的 appearance 仅作旧数据的一次性迁移来源。
    static var accentColor: String? {
        get { appearanceString(forKey: "paperico:appearance-accent") }
        set { setAppearanceString(newValue, forKey: "paperico:appearance-accent") }
    }

    static var themeMode: String? {
        get { appearanceString(forKey: "paperico:appearance-theme") }
        set { setAppearanceString(newValue, forKey: "paperico:appearance-theme") }
    }

    static var readingFontSize: Int? {
        get {
            guard d.object(forKey: "paperico:appearance-font-size") != nil else { return nil }
            let size = d.integer(forKey: "paperico:appearance-font-size")
            return size > 0 ? size : nil
        }
        set {
            guard let newValue else {
                d.removeObject(forKey: "paperico:appearance-font-size")
                return
            }
            d.set(newValue, forKey: "paperico:appearance-font-size")
        }
    }

    static var backgroundTransparency: Double {
        get { min(50, max(0, d.double(forKey: "paperico:background-transparency"))) }
        set { d.set(min(50, max(0, newValue.isFinite ? newValue : 0)), forKey: "paperico:background-transparency") }
    }

    /// Build-time tuning of component material, independent of the window canvas.
    static var glassTransparency: Double {
        get {
            guard d.object(forKey: "paperico:glass-transparency") != nil else { return 15 }
            return min(30, max(0, d.double(forKey: "paperico:glass-transparency")))
        }
        set { d.set(min(30, max(0, newValue.isFinite ? newValue : 15)), forKey: "paperico:glass-transparency") }
    }

    private static func appearanceString(forKey key: String) -> String? {
        let value = d.string(forKey: key)
        return (value?.isEmpty == false) ? value : nil
    }

    private static func setAppearanceString(_ value: String?, forKey key: String) {
        guard let value, !value.isEmpty else {
            d.removeObject(forKey: key)
            return
        }
        d.set(value, forKey: key)
    }
}
