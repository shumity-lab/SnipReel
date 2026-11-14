import AppKit

/// 鉛筆の色・太さ(全キャプチャ共通、UserDefaults に保存)
@MainActor
final class PenSettings {
    static let shared = PenSettings()

    static let presetColors: [(name: String, color: NSColor)] = [
        ("Red", .systemRed), ("Orange", .systemOrange), ("Yellow", .systemYellow),
        ("Green", .systemGreen), ("Blue", .systemBlue), ("Purple", .systemPurple),
        ("Black", .black), ("White", .white),
    ]
    static let presetWidths: [(name: String, width: CGFloat)] = [
        ("Extra Fine (1pt)", 1), ("Fine (2pt)", 2), ("Medium (4pt)", 4), ("Bold (8pt)", 8), ("Extra Bold (16pt)", 16),
    ]

    private let colorKey = "penColor"
    private let widthKey = "penWidth"

    var color: NSColor {
        didSet { saveColor() }
    }
    var width: CGFloat {
        didSet { UserDefaults.standard.set(Double(width), forKey: widthKey) }
    }

    private init() {
        let d = UserDefaults.standard
        if let c = d.array(forKey: colorKey) as? [Double], c.count == 4 {
            color = NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3])
        } else {
            color = .systemRed
        }
        let w = d.double(forKey: widthKey)
        width = w > 0 ? CGFloat(w) : 4
    }

    private func saveColor() {
        guard let c = color.usingColorSpace(.sRGB) else { return }
        UserDefaults.standard.set([Double(c.redComponent), Double(c.greenComponent),
                                   Double(c.blueComponent), Double(c.alphaComponent)], forKey: colorKey)
    }

    static func isSameColor(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return false }
        let e: CGFloat = 0.002
        return abs(x.redComponent - y.redComponent) < e && abs(x.greenComponent - y.greenComponent) < e
            && abs(x.blueComponent - y.blueComponent) < e && abs(x.alphaComponent - y.alphaComponent) < e
    }
}
