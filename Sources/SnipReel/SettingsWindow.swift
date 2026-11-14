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
    private let recorder: ShortcutRecorderButton
    private let statusLabel = NSTextField(labelWithString: "")
    var onShortcutChanged: ((Shortcut) -> Bool)?
    var onRecordingChanged: ((Bool) -> Void)?

    init(shortcut: Shortcut) {
        recorder = ShortcutRecorderButton(shortcut: shortcut)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 170),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L("SnipReel Settings")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let label = NSTextField(labelWithString: L("Capture shortcut:"))
        let resetButton = NSButton(title: L("Restore Default"), target: self, action: #selector(resetShortcut))
        let note = NSTextField(wrappingLabelWithString:
            L("Click the button, then press a new key combination. It must include ⌘, ⌃ or ⌥ (function keys can be used alone)."))
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .systemRed

        recorder.onChange = { [weak self] s in self?.apply(s) }
        recorder.onRecordingChanged = { [weak self] r in self?.onRecordingChanged?(r) }

        let row = NSStackView(views: [label, recorder, resetButton])
        row.orientation = .horizontal
        row.spacing = 8
        recorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        let stack = NSStackView(views: [row, note, statusLabel])
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

    private func apply(_ shortcut: Shortcut) {
        if onShortcutChanged?(shortcut) == true {
            statusLabel.stringValue = ""
        } else {
            statusLabel.stringValue = L("%@ is used by another app and couldn't be registered.", shortcut.displayString)
        }
    }

    @objc private func resetShortcut() {
        recorder.stopRecording()
        recorder.shortcut = .default
        apply(.default)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        recorder.stopRecording()
    }

    func windowDidResignKey(_ notification: Notification) {
        recorder.stopRecording()
    }
}
