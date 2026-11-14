import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var captureMenuItem: NSMenuItem!
    private var closeAllMenuItem: NSMenuItem!
    private var shortcut = Shortcut.load()
    private var settingsController: SettingsWindowController?

    private var overlays: [SelectionOverlayWindow] = []
    private var isCapturing = false
    private var captureWindows: [CaptureWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        HotKeyManager.shared.onPressed = { [weak self] in self?.startCapture() }
        if !HotKeyManager.shared.register(shortcut) {
            showAlert(L("Couldn't register the shortcut %@.", shortcut.displayString),
                      info: L("It may be used by another app. Change it from SnipReel in the menu bar → Settings…."))
        }

        // 初回起動時に画面収録の許可を求める
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    // MARK: メニューバー

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            // Resources/MenuBarIcon(@2x).png。見つからない場合(swift run など)は SF Symbol
            let image = Bundle.main.image(forResource: "MenuBarIcon")
                ?? NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "SnipReel")
            image?.size = NSSize(width: 18, height: 18)
            image?.isTemplate = true // ライト/ダークで自動的に色が変わる
            image?.accessibilityDescription = "SnipReel"
            button.image = image
        }
        let menu = NSMenu()
        menu.delegate = self

        captureMenuItem = NSMenuItem(title: "", action: #selector(captureFromMenu), keyEquivalent: "")
        captureMenuItem.target = self
        menu.addItem(captureMenuItem)

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
        updateMenuTitles()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateMenuTitles()
        closeAllMenuItem.isEnabled = !captureWindows.isEmpty
    }

    private func updateMenuTitles() {
        captureMenuItem.title = L("Capture Area (%@)", shortcut.displayString)
    }

    @objc private func captureFromMenu() {
        // メニューが閉じてからオーバーレイを出す
        DispatchQueue.main.async { [weak self] in self?.startCapture() }
    }

    @objc private func closeAllCaptures() {
        for w in captureWindows { w.close() }
    }

    @objc private func openSettings() {
        if settingsController == nil {
            let c = SettingsWindowController(shortcut: shortcut)
            c.onShortcutChanged = { [weak self] new in self?.changeShortcut(new) ?? false }
            c.onRecordingChanged = { [weak self] recording in
                guard let self else { return }
                // 記録中は今のホットキーを止める(押してもキャプチャが始まらないように)
                if recording { HotKeyManager.shared.unregister() } else { HotKeyManager.shared.register(self.shortcut) }
            }
            settingsController = c
        }
        settingsController?.show()
    }

    private func changeShortcut(_ new: Shortcut) -> Bool {
        if HotKeyManager.shared.register(new) {
            shortcut = new
            shortcut.save()
            updateMenuTitles()
            return true
        }
        HotKeyManager.shared.register(shortcut) // 元に戻す
        return false
    }

    // MARK: キャプチャ

    private func startCapture() {
        guard !isCapturing else { return }
        isCapturing = true
        NSApp.activate(ignoringOtherApps: true)

        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            let w = SelectionOverlayWindow(screen: screen) { [weak self] window, rect in
                self?.finishSelection(window: window, rect: rect)
            }
            overlays.append(w)
            w.orderFrontRegardless()
            if NSMouseInRect(mouse, screen.frame, false) { w.makeKey() }
        }
        if !overlays.contains(where: { $0.isKeyWindow }) { overlays.first?.makeKey() }
    }

    private func finishSelection(window: SelectionOverlayWindow, rect: CGRect?) {
        let currentOverlays = overlays
        guard let rect else {
            endCapture(currentOverlays)
            return
        }
        // 選択枠を消してから撮る(オーバーレイ自体は除外指定もしておく)
        for o in currentOverlays { o.contentView?.isHidden = true; o.displayIfNeeded() }
        let screen = window.targetScreen
        let excluded = currentOverlays.map { $0.windowNumber }

        Task { @MainActor in
            defer { self.endCapture(currentOverlays) }
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

    private func endCapture(_ windows: [SelectionOverlayWindow]) {
        for w in windows { w.orderOut(nil) }
        overlays.removeAll { windows.contains($0) }
        isCapturing = false
    }

    private func showCapture(_ image: CGImage, frame: NSRect) {
        Clipboard.copy(image, pointSize: frame.size)
        let w = CaptureWindow(image: image, imageFrame: frame)
        w.onClose = { [weak self] closed in self?.captureWindows.removeAll { $0 === closed } }
        captureWindows.append(w)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func handleCaptureError(_ error: Error) {
        if !CGPreflightScreenCaptureAccess() {
            let alert = NSAlert()
            alert.messageText = L("Screen Recording permission is required")
            alert.informativeText = L("Allow SnipReel in System Settings → Privacy & Security → Screen & System Audio Recording, then restart SnipReel.")
            alert.addButton(withTitle: L("Open System Settings"))
            alert.addButton(withTitle: L("Close"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn,
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
        alert.runModal()
    }
}
