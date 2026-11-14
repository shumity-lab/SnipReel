import AppKit

/// ダイアログ(NSAlert / NSSavePanel)をモーダル表示する。
/// runModal() はダイアログのレベルを modalPanel に戻すため、それより上にある
/// 自分の最前面ウインドウ(キャプチャ・動画・録画枠など)の裏に隠れて操作不能になる。
/// 表示中だけそれらのウインドウを一時的に下げる。
@MainActor
enum ModalPresenter {
    @discardableResult
    static func run<T>(_ body: () -> T) -> T {
        let lowered: [(NSWindow, NSWindow.Level)] = NSApp.windows.compactMap { w in
            guard w.isVisible, w.level >= .modalPanel,
                  w is CaptureWindow || w is VideoWindow || w is RecordingFrameWindow
                      || w is RecordingControlPanel || w is NSColorPanel
            else { return nil }
            return (w, w.level)
        }
        for (w, _) in lowered { w.level = .floating }
        defer { for (w, level) in lowered { w.level = level } }
        NSApp.activate(ignoringOtherApps: true)
        return body()
    }
}
