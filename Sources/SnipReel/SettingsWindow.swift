import AppKit

/// クリックしてからキーを押すとショートカットを記録するボタン
final class ShortcutRecorderButton: NSButton {
    var shortcut: Shortcut { didSet { updateTitle() } }
    var onChange: ((Shortcut) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    private var monitor: Any?
    private(set) var isRecording = false

    init(shortcut: Shortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording)
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        onRecordingChanged?(true)
        updateTitle()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            self.handle(event)
            return nil
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        updateTitle()
        onRecordingChanged?(false)
    }

    private func handle(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection(Shortcut.relevantModifiers)
        let keyCode = UInt32(event.keyCode)
        if keyCode == 53 && mods.isEmpty { // Esc → キャンセル
            stopRecording()
            return
        }
        // ⌘ / ⌃ / ⌥ のいずれかが必要(F キーは単独でも可)
        let hasMainModifier = !mods.intersection([.command, .control, .option]).isEmpty
        guard hasMainModifier || Shortcut.isFunctionKey(keyCode) else {
            NSSound.beep()
            return
        }
        let new = Shortcut(keyCode: keyCode, modifiers: mods.rawValue)
        stopRecording()
        shortcut = new
        onChange?(new)
    }

    private func updateTitle() {
        title = isRecording ? L("Press keys… (Esc to cancel)") : shortcut.displayString
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var recorders: [HotKeyAction: ShortcutRecorderButton] = [:]
    private let statusLabel = NSTextField(labelWithString: "")
    /// 登録できたら nil、できなければエラーメッセージ
    var onShortcutChanged: ((HotKeyAction, Shortcut) -> String?)?
    /// キー入力の記録中かどうか(記録中はホットキーを止める)
    var onRecordingChanged: ((Bool) -> Void)?

    init(shortcuts: [HotKeyAction: Shortcut]) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L("SnipReel Settings")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        for action in HotKeyAction.allCases {
            recorders[action] = ShortcutRecorderButton(shortcut: shortcuts[action] ?? action.defaultShortcut)
        }
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func title(for action: HotKeyAction) -> String {
        switch action {
        case .capture: return L("Capture shortcut:")
        case .record: return L("Recording shortcut:")
        }
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        var rows: [[NSView]] = []
        for action in HotKeyAction.allCases {
            guard let recorder = recorders[action] else { continue }
            recorder.onChange = { [weak self] s in self?.apply(s, for: action) }
            recorder.onRecordingChanged = { [weak self] r in self?.onRecordingChanged?(r) }
            recorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
            let reset = NSButton(title: L("Restore Default"), target: self, action: #selector(resetShortcut(_:)))
            reset.tag = Int(action.rawValue)
            rows.append([NSTextField(labelWithString: title(for: action)), recorder, reset])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        let note = NSTextField(wrappingLabelWithString:
            L("Click the button, then press a new key combination. It must include ⌘, ⌃ or ⌥ (function keys can be used alone)."))
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .systemRed

        let stack = NSStackView(views: [grid, note, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func apply(_ shortcut: Shortcut, for action: HotKeyAction) {
        if let error = onShortcutChanged?(action, shortcut) {
            statusLabel.stringValue = error
        } else {
            statusLabel.stringValue = ""
        }
    }

    /// 登録に失敗した時などに表示を戻す
    func setShortcut(_ shortcut: Shortcut, for action: HotKeyAction) {
        recorders[action]?.shortcut = shortcut
    }

    @objc private func resetShortcut(_ sender: NSButton) {
        guard let action = HotKeyAction(rawValue: UInt32(sender.tag)) else { return }
        recorders[action]?.stopRecording()
        recorders[action]?.shortcut = action.defaultShortcut
        apply(action.defaultShortcut, for: action)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func stopAllRecording() {
        for r in recorders.values { r.stopRecording() }
    }

    func windowWillClose(_ notification: Notification) { stopAllRecording() }
    func windowDidResignKey(_ notification: Notification) { stopAllRecording() }
}
