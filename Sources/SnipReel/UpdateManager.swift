import AppKit
import Sparkle

/// Sparkle による自動アップデート。
/// 更新情報(appcast.xml)は GitHub Releases の最新リリースに添付したものを読む(Info.plist の SUFeedURL)。
@MainActor
final class UpdateManager: NSObject, SPUStandardUserDriverDelegate {
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
    private var started = false

    /// .app として起動した時だけ動かす(swift run では Info.plist がないため)
    func start() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        do {
            try controller.updater.start()
            started = true
        } catch {
            NSLog("SnipReel: couldn't start the updater: \(error)")
        }
    }

    func makeMenuItem() -> NSMenuItem? {
        guard started else { return nil }
        let item = NSMenuItem(title: L("Check for Updates…"),
                              action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                              keyEquivalent: "")
        item.target = controller
        return item
    }

    // MARK: SPUStandardUserDriverDelegate

    /// メニューバー常駐アプリなので、定期チェックで見つかった更新の表示を Sparkle に任せつつ前面に出す
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                               forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        MainActor.assumeIsolated {
            // キャプチャ・動画ウインドウ(最前面)の裏に隠れないようにアプリを前面に出す
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
