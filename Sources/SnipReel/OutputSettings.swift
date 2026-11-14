import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 保存・コピー時の出力形式
enum OutputFormat: Int, CaseIterable {
    case png, jpegHigh, jpegMedium, jpegLow

    var title: String {
        switch self {
        case .png: return L("PNG (lossless)")
        case .jpegHigh: return L("JPEG High (90%)")
        case .jpegMedium: return L("JPEG Medium (75%)")
        case .jpegLow: return L("JPEG Low (50%)")
        }
    }

    var shortTitle: String {
        switch self {
        case .png: return "PNG"
        case .jpegHigh: return L("JPEG High")
        case .jpegMedium: return L("JPEG Med")
        case .jpegLow: return L("JPEG Low")
        }
    }

    var utType: UTType { self == .png ? .png : .jpeg }
    var fileExtension: String { self == .png ? "png" : "jpg" }

    var quality: CGFloat? {
        switch self {
        case .png: return nil
        case .jpegHigh: return 0.9
        case .jpegMedium: return 0.75
        case .jpegLow: return 0.5
        }
    }
}

/// 最後に選んだ出力形式を記憶する
@MainActor
final class OutputSettings {
    static let shared = OutputSettings()
    private let key = "outputFormat"

    var format: OutputFormat {
        didSet { UserDefaults.standard.set(format.rawValue, forKey: key) }
    }

    private init() {
        format = OutputFormat(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .png
    }
}

enum ImageEncoder {
    /// 指定ピクセルサイズに縮小・拡大する
    static func scaled(_ image: CGImage, width: Int, height: Int) -> CGImage {
        guard width != image.width || height != image.height else { return image }
        let space = (image.colorSpace?.model == .rgb ? image.colorSpace : nil)
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? image
    }

    /// - Parameter dpi: 72 × 画面の倍率(Retina なら 144)。他アプリで開いた時の表示サイズに使われる
    static func encode(_ image: CGImage, format: OutputFormat, dpi: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil)
        else { return nil }
        var props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        if let q = format.quality {
            props[kCGImageDestinationLossyCompressionQuality] = q
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
