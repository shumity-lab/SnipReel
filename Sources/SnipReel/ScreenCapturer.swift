import AppKit
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case displayNotFound

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return L("The display to capture was not found.")
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

enum ScreenCapturer {
    /// - Parameters:
    ///   - rect: スクリーン内のローカル座標(ポイント、左下原点)
    ///   - excludingWindowNumbers: 写り込ませない自アプリのウインドウ(選択オーバーレイなど)
    @MainActor
    static func capture(rect: CGRect, on screen: NSScreen, excludingWindowNumbers: [Int]) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let displayID = screen.displayID,
              let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }
        let excluded = content.windows.filter { excludingWindowNumbers.contains(Int($0.windowID)) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)

        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        // ScreenCaptureKit の sourceRect は左上原点
        config.sourceRect = CGRect(x: rect.minX, y: screen.frame.height - rect.maxY,
                                   width: rect.width, height: rect.height)
        config.width = max(1, Int((rect.width * scale).rounded()))
        config.height = max(1, Int((rect.height * scale).rounded()))
        config.showsCursor = false
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
