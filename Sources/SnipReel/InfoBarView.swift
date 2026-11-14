import AppKit

/// キャプチャの上に出す帯(閉じる・寸法・ファイルサイズ・サイズ変更・形式・コピー・保存)
final class InfoBarView: NSVisualEffectView {
    static let height: CGFloat = 30

    var onClose: (() -> Void)?
    var onScaleSelected: ((CGFloat) -> Void)?
    var onCustomSize: (() -> Void)?
    var onFormatSelected: ((OutputFormat) -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?

    private let pixelLabel = NSTextField(labelWithString: "")
    private let fileLabel = NSTextField(labelWithString: "")
    private let scalePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let stack = NSStackView()
    private var flashWorkItem: DispatchWorkItem?
    private var fileSizeText = ""

    private static let presetPercents = [100, 75, 50, 33, 25]

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: InfoBarView.height))
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .vibrantDark)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
        let b = NSButton(image: image, target: self, action: action)
        b.isBordered = false
        b.contentTintColor = .white
        b.toolTip = tip
        b.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        b.widthAnchor.constraint(equalToConstant: 22).isActive = true
        return b
    }

    private func buildUI() {
        let close = iconButton("xmark.circle.fill", L("Close (Esc)"), #selector(closeTapped))

        for label in [pixelLabel, fileLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            label.lineBreakMode = .byClipping
        }
        pixelLabel.textColor = .white
        fileLabel.textColor = .secondaryLabelColor
        pixelLabel.widthAnchor.constraint(equalToConstant: 96).isActive = true
        fileLabel.widthAnchor.constraint(equalToConstant: 82).isActive = true
        pixelLabel.toolTip = L("Pixel size of the output image")
        fileLabel.toolTip = L("File size when saved in the current format")

        for p in [scalePopup, formatPopup] {
            p.controlSize = .small
            p.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            p.target = self
        }
        scalePopup.action = #selector(scaleChanged)
        scalePopup.toolTip = L("Resize")
        formatPopup.action = #selector(formatChanged)
        formatPopup.toolTip = L("Save format (JPEG makes the file smaller)")
        for f in OutputFormat.allCases {
            formatPopup.addItem(withTitle: f.title)
            formatPopup.lastItem?.tag = f.rawValue
        }

        let copy = iconButton("doc.on.doc", L("Copy (⌘C)"), #selector(copyTapped))
        let save = iconButton("square.and.arrow.down", L("Save (⌘S)"), #selector(saveTapped))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        for v in [close, pixelLabel, fileLabel, spacer, scalePopup, formatPopup, copy, save] {
            stack.addArrangedSubview(v)
        }
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
        setScale(1)
    }

    /// 帯に必要な最小の幅
    var minimumWidth: CGFloat {
        layoutSubtreeIfNeeded()
        return ceil(stack.fittingSize.width)
    }

    // MARK: 表示の更新

    func setPixelSize(width: Int, height: Int) {
        pixelLabel.stringValue = "\(width) × \(height) px"
    }

    /// nil のときは計算中
    func setFileSize(_ bytes: Int?) {
        fileSizeText = bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? L("Calculating…")
        if flashWorkItem == nil { fileLabel.stringValue = fileSizeText }
    }

    func setFormat(_ format: OutputFormat) {
        formatPopup.selectItem(withTag: format.rawValue)
        formatPopup.title = format.shortTitle
    }

    func setScale(_ scale: CGFloat) {
        let percent = Int((scale * 100).rounded())
        scalePopup.removeAllItems()
        if !InfoBarView.presetPercents.contains(percent) {
            scalePopup.addItem(withTitle: "\(percent)%")
            scalePopup.lastItem?.tag = percent
        }
        for p in InfoBarView.presetPercents {
            scalePopup.addItem(withTitle: "\(p)%")
            scalePopup.lastItem?.tag = p
        }
        scalePopup.menu?.addItem(.separator())
        scalePopup.addItem(withTitle: L("Custom Size…"))
        scalePopup.lastItem?.tag = -1
        scalePopup.selectItem(withTag: percent)
    }

    /// 一時的にメッセージを表示(例: コピーしました)
    func flash(_ message: String) {
        flashWorkItem?.cancel()
        fileLabel.stringValue = message
        fileLabel.textColor = .systemGreen
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.flashWorkItem = nil
            self.fileLabel.textColor = .secondaryLabelColor
            self.fileLabel.stringValue = self.fileSizeText
        }
        flashWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }

    // MARK: 操作

    @objc private func closeTapped() { onClose?() }
    @objc private func copyTapped() { onCopy?() }
    @objc private func saveTapped() { onSave?() }

    @objc private func scaleChanged() {
        let tag = scalePopup.selectedTag()
        if tag > 0 {
            onScaleSelected?(CGFloat(tag) / 100)
        } else {
            onCustomSize?()
        }
    }

    @objc private func formatChanged() {
        if let f = OutputFormat(rawValue: formatPopup.selectedTag()) {
            setFormat(f)
            onFormatSelected?(f)
        }
    }

    // 帯の何もない所をドラッグするとウインドウを移動
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
