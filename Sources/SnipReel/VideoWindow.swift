import AppKit
import AVKit
import UniformTypeIdentifiers

/// 録画した動画を最前面で表示するウインドウ(上部に情報帯)
final class VideoWindow: NSWindow {
    var onClose: ((VideoWindow) -> Void)?
    let fileURL: URL
    private let playerView = AVPlayerView()
    private let bar = VideoBarView()
    private var isSaved = false
    private var forceClose = false

    /// - Parameter region: 録画した範囲(グローバル座標)。その位置に重ねて表示する
    init(fileURL: URL, region: NSRect) {
        self.fileURL = fileURL
        super.init(contentRect: region, styleMask: [.borderless], backing: .buffered, defer: false)
        level = CaptureWindow.captureLevel
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        playerView.player = AVPlayer(url: fileURL)
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = false
        playerView.wantsLayer = true
        playerView.layer?.backgroundColor = NSColor.black.cgColor

        bar.onClose = { [weak self] in self?.close() }
        bar.onCopy = { [weak self] in self?.copyFile() }
        bar.onSave = { [weak self] in self?.saveFile() }

        let container = NSView()
        container.addSubview(playerView)
        container.addSubview(bar)
        contentView = container
        initialFirstResponder = playerView

        // 大きすぎる場合は画面の 70% に収める
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(region) }) ?? NSScreen.main!
        let v = screen.visibleFrame
        var size = region.size
        let fit = min(1, v.width * 0.7 / size.width, (v.height * 0.7 - VideoBarView.height) / size.height)
        size = NSSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
        let width = max(size.width, bar.minimumWidth)
        var frame = NSRect(x: region.minX, y: region.minY, width: width, height: size.height + VideoBarView.height)
        if fit < 1 {
            frame.origin = NSPoint(x: v.midX - frame.width / 2, y: v.midY - frame.height / 2)
        } else if frame.maxY > v.maxY {
            frame.origin.y -= frame.maxY - v.maxY
        }
        setFrame(frame, display: false)
        playerView.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        bar.frame = NSRect(x: 0, y: size.height, width: width, height: VideoBarView.height)

        Task { await loadInfo() }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private func loadInfo() async {
        let asset = AVURLAsset(url: fileURL)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        var pixel = CGSize.zero
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            pixel = (try? await track.load(.naturalSize)) ?? .zero
        }
        let bytes = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        bar.setInfo(duration: duration, width: Int(pixel.width), height: Int(pixel.height), bytes: bytes)
    }

    // MARK: 操作

    func copyFile() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([fileURL as NSURL])
        bar.flash(L("Copied"))
    }

    func saveFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        panel.nameFieldStringValue = "SnipReel \(f.string(from: Date())).mp4"
        NSApp.activate(ignoringOtherApps: true)
        defer { makeKeyAndOrderFront(nil) }
        guard ModalPresenter.run({ panel.runModal() }) == .OK, let url = panel.url else { return }
        do {
            let fm = FileManager.default
            if url.standardizedFileURL.resolvingSymlinksInPath()
                == fileURL.standardizedFileURL.resolvingSymlinksInPath() {
                // 一時ファイル自身が選ばれた: 何もしなくてよい
            } else if fm.fileExists(atPath: url.path) {
                // 上書きは保存ダイアログで確認済み。
                // 先に一時ファイルへコピーしてから差し替え、失敗しても既存のファイルは残す
                let tmpDir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                        appropriateFor: url, create: true)
                defer { try? fm.removeItem(at: tmpDir) }
                let tmp = tmpDir.appendingPathComponent(url.lastPathComponent)
                try fm.copyItem(at: fileURL, to: tmp)
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.copyItem(at: fileURL, to: url)
            }
            isSaved = true
            bar.flash(L("Saved"))
        } catch {
            let alert = NSAlert(error: error)
            ModalPresenter.run({ alert.runModal() })
        }
    }

    /// 未保存なら確認してから閉じる
    override func close() {
        if !isSaved && !forceClose && isVisible {
            playerView.player?.pause()
            let alert = NSAlert()
            alert.messageText = L("This recording hasn't been saved.")
            alert.informativeText = L("Close it anyway?")
            alert.addButton(withTitle: L("Close"))
            alert.addButton(withTitle: L("Cancel"))
            alert.buttons.first?.hasDestructiveAction = true
            NSApp.activate(ignoringOtherApps: true)
            guard ModalPresenter.run({ alert.runModal() }) == .alertFirstButtonReturn else { return }
        }
        playerView.player?.pause()
        playerView.player = nil
        super.close()
        onClose?(self)
        onClose = nil
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(Shortcut.relevantModifiers)
        guard flags == [.command] else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "s": saveFile(); return true
        case "c": copyFile(); return true
        case "w": close(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { close() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }
}

/// 動画ウインドウの上部の帯(閉じる・長さ・解像度・ファイルサイズ・コピー・保存)
final class VideoBarView: NSVisualEffectView {
    static let height: CGFloat = 30

    var onClose: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?

    private let infoLabel = NSTextField(labelWithString: "")
    private let fileLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var fileText = ""
    private var flashItem: DispatchWorkItem?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: VideoBarView.height))
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .vibrantDark)

        func icon(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(),
                             target: self, action: action)
            b.isBordered = false
            b.contentTintColor = .white
            b.toolTip = tip
            b.symbolConfiguration = .init(pointSize: 13, weight: .medium)
            b.widthAnchor.constraint(equalToConstant: 22).isActive = true
            return b
        }
        let close = icon("xmark.circle.fill", L("Close (Esc)"), #selector(closeTapped))
        for l in [infoLabel, fileLabel] {
            l.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            l.lineBreakMode = .byClipping
        }
        infoLabel.textColor = .white
        fileLabel.textColor = .secondaryLabelColor
        infoLabel.widthAnchor.constraint(equalToConstant: 150).isActive = true
        fileLabel.widthAnchor.constraint(equalToConstant: 82).isActive = true
        infoLabel.stringValue = "--:--"
        fileLabel.stringValue = L("Calculating…")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let copy = icon("doc.on.doc", L("Copy file (⌘C)"), #selector(copyTapped))
        let save = icon("square.and.arrow.down", L("Save (⌘S)"), #selector(saveTapped))

        for v in [close, infoLabel, fileLabel, spacer, copy, save] { stack.addArrangedSubview(v) }
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.setCustomSpacing(10, after: close)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    var minimumWidth: CGFloat {
        layoutSubtreeIfNeeded()
        return ceil(stack.fittingSize.width)
    }

    func setInfo(duration: TimeInterval, width: Int, height: Int, bytes: Int) {
        infoLabel.stringValue = "\(RecordingController.format(duration))  \(width) × \(height)"
        fileText = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        if flashItem == nil { fileLabel.stringValue = fileText }
    }

    func flash(_ message: String) {
        flashItem?.cancel()
        fileLabel.stringValue = message
        fileLabel.textColor = .systemGreen
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.flashItem = nil
            self.fileLabel.textColor = .secondaryLabelColor
            self.fileLabel.stringValue = self.fileText
        }
        flashItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }

    @objc private func closeTapped() { onClose?() }
    @objc private func copyTapped() { onCopy?() }
    @objc private func saveTapped() { onSave?() }

    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
