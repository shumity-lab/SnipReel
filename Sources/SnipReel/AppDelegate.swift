import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var captureMenuItem: NSMenuItem!
    private var recordMenuItem: NSMenuItem!
    private var closeAllMenuItem: NSMenuItem!
    private var shortcuts: [HotKeyAction: Shortcut] = [:]
    private var settingsController: SettingsWindowController?

    private var overlays: [SelectionOverlayWindow] = []
    private var isSelecting = false
    private var captureWindows: [CaptureWindow] = []
    private var videoWindows: [VideoWindow] = []
    private var recording: RecordingController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        RecordingFiles.cleanUpOldFiles()
        setupStatusItem()

        HotKeyManager.shared.onPressed = { [weak self] action in self?.handleHotKey(action) }
        var failed: [String] = []
        for action in HotKeyAction.allCases {
            let s = Shortcut.load(for: action)
            shortcuts[action] = s
            if !HotKeyManager.shared.register(s, for: action) { failed.append(s.displayString) }
        }
        updateMenuTitles()
        if !failed.isEmpty {
            showAlert(L("Couldn't register the shortcut %@.", failed.joined(separator: ", ")),
                      info: L("It may be used by another app. Change it from SnipReel in the menu bar → Settings…."))
        }

        // 初回起動時に画面収録の許可を求める
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    private func handleHotKey(_ action: HotKeyAction) {
        switch action {
        case .capture:
            guard recording == nil else { return }
            startSelection(mode: .capture)
        case .record:
            if let recording {
                recording.stop() // 録画中にもう一度押すと停止
            } else {
                startSelection(mode: .record)
            }
        }
    }

    // MARK: メニューバー

    private var normalIcon: NSImage? {
        // Resources/MenuBarIcon(@2x).png。見つからない場合(swift run など)は SF Symbol
        let image = Bundle.main.image(forResource: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "SnipReel")
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true // ライト/ダークで自動的に色が変わる
        image?.accessibilityDescription = "SnipReel"
        return image
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = normalIcon

        menu = NSMenu()
        menu.delegate = self

        captureMenuItem = NSMenuItem(title: "", action: #selector(captureFromMenu), keyEquivalent: "")
        captureMenuItem.target = self
        menu.addItem(captureMenuItem)

        recordMenuItem = NSMenuItem(title: "", action: #selector(recordFromMenu), keyEquivalent: "")
        recordMenuItem.target = self
        menu.addItem(recordMenuItem)

        menu.addItem(.separator())
        closeAllMenuItem = NSMenuItem(title: L("Close All Captures"), action: #selector(closeAllCaptures), keyEquivalent: "")
        closeAllMenuItem.target = self
        menu.addItem(closeAllMenuItem)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: L("Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Quit SnipReel"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateMenuTitles()
        closeAllMenuItem.isEnabled = !captureWindows.isEmpty || !videoWindows.isEmpty
    }

    private func updateMenuTitles() {
        let cap = shortcuts[.capture]?.displayString ?? ""
        let rec = shortcuts[.record]?.displayString ?? ""
        captureMenuItem?.title = L("Capture Area (%@)", cap)
        recordMenuItem?.title = L("Record Screen (%@)", rec)
    }

    /// 録画中はアイコンを赤い録画マーク + 経過時間にし、クリックで停止
    private func setRecordingStatus(_ active: Bool) {
        guard let button = statusItem.button else { return }
        if active {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
                .applying(.init(paletteColors: [.white, .systemRed]))
            let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: L("Stop recording"))?
                .withSymbolConfiguration(config)
            image?.isTemplate = false
            button.image = image
            button.imagePosition = .imageLeading
            button.title = " 00:00"
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            button.toolTip = L("Stop recording")
            statusItem.menu = nil
            button.target = self
            button.action = #selector(stopRecordingFromStatusItem)
        } else {
            button.image = normalIcon
            button.title = ""
            button.toolTip = nil
            button.action = nil
            statusItem.menu = menu
        }
    }

    @objc private func stopRecordingFromStatusItem() {
        recording?.stop()
    }

    @objc private func captureFromMenu() {
        // メニューが閉じてからオーバーレイを出す
        DispatchQueue.main.async { [weak self] in self?.handleHotKey(.capture) }
    }

    @objc private func recordFromMenu() {
        DispatchQueue.main.async { [weak self] in self?.handleHotKey(.record) }
    }

    @objc private func closeAllCaptures() {
        for w in captureWindows { w.close() }
        for w in videoWindows { w.close() }
    }

    // MARK: 設定

    @objc private func openSettings() {
        if settingsController == nil {
            let c = SettingsWindowController(shortcuts: shortcuts)
            c.onShortcutChanged = { [weak self] action, new in self?.changeShortcut(new, for: action) }
            c.onRecordingChanged = { [weak self] recording in
                guard let self else { return }
                // キー入力の記録中はホットキーを止める(押しても動作しないように)
                if recording {
                    HotKeyManager.shared.unregisterAll()
                } else {
                    for (action, s) in self.shortcuts { HotKeyManager.shared.register(s, for: action) }
                }
            }
            settingsController = c
        }
        settingsController?.show()
    }

    /// 成功なら nil、失敗ならエラーメッセージ
    private func changeShortcut(_ new: Shortcut, for action: HotKeyAction) -> String? {
        let old = shortcuts[action] ?? action.defaultShortcut
        if shortcuts.contains(where: { $0.key != action && $0.value == new }) {
            settingsController?.setShortcut(old, for: action)
            return L("%@ is already used by another SnipReel shortcut.", new.displayString)
        }
        if HotKeyManager.shared.register(new, for: action) {
            shortcuts[action] = new
            new.save(for: action)
            updateMenuTitles()
            return nil
        }
        HotKeyManager.shared.register(old, for: action) // 元に戻す
        settingsController?.setShortcut(old, for: action)
        return L("%@ is used by another app and couldn't be registered.", new.displayString)
    }

    // MARK: 範囲選択

    private func startSelection(mode: SelectionMode) {
        guard !isSelecting else { return }
        isSelecting = true
        NSApp.activate(ignoringOtherApps: true)

        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            let w = SelectionOverlayWindow(screen: screen, mode: mode) { [weak self] window, rect in
                self?.finishSelection(window: window, rect: rect, mode: mode)
            }
            overlays.append(w)
            w.orderFrontRegardless()
            if NSMouseInRect(mouse, screen.frame, false) { w.makeKey() }
        }
        if !overlays.contains(where: { $0.isKeyWindow }) { overlays.first?.makeKey() }
    }

    private func finishSelection(window: SelectionOverlayWindow, rect: CGRect?, mode: SelectionMode) {
        let currentOverlays = overlays
        guard let rect else {
            endSelection(currentOverlays)
            return
        }
        let screen = window.targetScreen
        switch mode {
        case .capture:
            capture(rect: rect, screen: screen, overlays: currentOverlays)
        case .record:
            endSelection(currentOverlays)
            startRecording(rect: rect, screen: screen)
        }
    }

    private func endSelection(_ windows: [SelectionOverlayWindow]) {
        for w in windows { w.orderOut(nil) }
        overlays.removeAll { windows.contains($0) }
        isSelecting = false
    }

    // MARK: キャプチャ

    private func capture(rect: CGRect, screen: NSScreen, overlays currentOverlays: [SelectionOverlayWindow]) {
        // 選択枠を消してから撮る(オーバーレイ自体は除外指定もしておく)
        for o in currentOverlays { o.contentView?.isHidden = true; o.displayIfNeeded() }
        let excluded = currentOverlays.map { $0.windowNumber }

        Task { @MainActor in
            defer { self.endSelection(currentOverlays) }
            do {
                let image = try await ScreenCapturer.capture(rect: rect, on: screen, excludingWindowNumbers: excluded)
                let globalFrame = NSRect(x: screen.frame.minX + rect.minX, y: screen.frame.minY + rect.minY,
                                         width: rect.width, height: rect.height)
                self.showCapture(image, frame: globalFrame)
            } catch {
                self.handleCaptureError(error)
            }
        }
    }

    private func showCapture(_ image: CGImage, frame: NSRect) {
        Clipboard.copy(image, pointSize: frame.size)
        let w = CaptureWindow(image: image, imageFrame: frame)
        w.onClose = { [weak self] closed in self?.captureWindows.removeAll { $0 === closed } }
        captureWindows.append(w)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    // MARK: 録画

    private func startRecording(rect: CGRect, screen: NSScreen) {
        let controller = RecordingController(screen: screen, localRect: rect)
        controller.onTick = { [weak self] elapsed in
            self?.statusItem.button?.title = " " + RecordingController.format(elapsed)
        }
        controller.onFinished = { [weak self] c, url, error in
            guard let self else { return }
            self.recording = nil
            self.setRecordingStatus(false)
            if let url {
                self.showVideo(url, region: c.region)
            } else if let error {
                self.handleCaptureError(error)
            }
        }
        recording = controller
        setRecordingStatus(true)
        controller.begin()
    }

    private func showVideo(_ url: URL, region: NSRect) {
        let w = VideoWindow(fileURL: url, region: region)
        w.onClose = { [weak self] closed in self?.videoWindows.removeAll { $0 === closed } }
        videoWindows.append(w)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    // MARK: エラー

    private func handleCaptureError(_ error: Error) {
        if !CGPreflightScreenCaptureAccess() {
            let alert = NSAlert()
            alert.messageText = L("Screen Recording permission is required")
            alert.informativeText = L("Allow SnipReel in System Settings → Privacy & Security → Screen & System Audio Recording, then restart SnipReel.")
            alert.addButton(withTitle: L("Open System Settings"))
            alert.addButton(withTitle: L("Close"))
            NSApp.activate(ignoringOtherApps: true)
            if ModalPresenter.run({ alert.runModal() }) == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        } else {
            showAlert(L("Capture failed"), info: error.localizedDescription)
        }
    }

    private func showAlert(_ message: String, info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        NSApp.activate(ignoringOtherApps: true)
        ModalPresenter.run({ alert.runModal() })
    }
}
