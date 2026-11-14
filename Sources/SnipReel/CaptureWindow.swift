import AppKit
import UniformTypeIdentifiers

/// キャプチャ画像を常に最前面に表示するウインドウ(上部に情報帯)
final class CaptureWindow: NSWindow {
    /// 通常のフローティングウインドウよりも前面に出す
    static let captureLevel = NSWindow.Level.statusBar

    let captureView: CaptureView
    let infoBar = InfoBarView()
    private let container = NSView()
    var onClose: ((CaptureWindow) -> Void)?

    /// 元画像に対する出力倍率(表示サイズにも反映)
    private(set) var outputScale: CGFloat = 1
    /// 元画像の 1pt あたりのピクセル数(Retina = 2)
    private let backingScale: CGFloat
    private var fileSizeGeneration = 0

    /// - Parameter imageFrame: キャプチャした範囲(グローバル座標、ポイント)
    init(image: CGImage, imageFrame: NSRect) {
        captureView = CaptureView(image: image, baseSize: imageFrame.size)
        backingScale = CGFloat(image.width) / max(imageFrame.width, 1)
        super.init(contentRect: imageFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = CaptureWindow.captureLevel
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        container.addSubview(captureView)
        container.addSubview(infoBar)
        contentView = container
        initialFirstResponder = captureView

        infoBar.onClose = { [weak self] in self?.close() }
        infoBar.onCopy = { [weak self] in self?.copyOutput() }
        infoBar.onSave = { [weak self] in self?.saveOutput() }
        infoBar.onScaleSelected = { [weak self] s in self?.setOutputScale(s) }
        infoBar.onCustomSize = { [weak self] in self?.promptCustomSize() }
        infoBar.onFormatSelected = { [weak self] f in
            OutputSettings.shared.format = f
            self?.refreshInfo()
            self?.focusImage()
        }
        captureView.onStrokesChanged = { [weak self] in self?.scheduleFileSizeUpdate() }

        // 画像は撮った位置に重ね、帯はその上に出す(画面上端からはみ出す場合は下にずらす)
        var frame = frameFor(imageSize: imageFrame.size, imageOrigin: imageFrame.origin)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(imageFrame) }) {
            let overflow = frame.maxY - screen.visibleFrame.maxY
            if overflow > 0 { frame.origin.y -= overflow }
        }
        setFrame(frame, display: false)
        layoutContents()
        refreshInfo()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func close() {
        super.close()
        onClose?(self)
        onClose = nil
    }

    // MARK: レイアウト

    private var displayImageSize: NSSize {
        NSSize(width: max(1, (captureView.baseSize.width * outputScale).rounded()),
               height: max(1, (captureView.baseSize.height * outputScale).rounded()))
    }

    private func frameFor(imageSize: NSSize, imageOrigin: NSPoint) -> NSRect {
        let width = max(imageSize.width, infoBar.minimumWidth)
        return NSRect(x: imageOrigin.x, y: imageOrigin.y, width: width, height: imageSize.height + InfoBarView.height)
    }

    private func layoutContents() {
        let img = displayImageSize
        captureView.frame = NSRect(origin: .zero, size: img)
        captureView.displayScale = outputScale
        infoBar.frame = NSRect(x: 0, y: img.height, width: frame.width, height: InfoBarView.height)
        invalidateShadow()
    }

    // MARK: サイズ変更

    /// ドラッグされる角(反対側の角が固定される)
    enum Corner {
        case topLeft, topRight, bottomLeft, bottomRight
        var isRight: Bool { self == .topRight || self == .bottomRight }
        var isTop: Bool { self == .topLeft || self == .topRight }
    }

    /// 画像部分のスクリーン座標
    var imageRectOnScreen: NSRect {
        NSRect(origin: frame.origin, size: displayImageSize)
    }

    /// 画像の左上を固定して倍率を変更(帯のメニューから)
    func setOutputScale(_ scale: CGFloat) {
        let img = imageRectOnScreen
        setOutputScale(scale, anchor: NSPoint(x: img.minX, y: img.maxY), dragging: .bottomRight, live: false)
        focusImage()
    }

    static let minScale: CGFloat = 0.02
    static let maxScale: CGFloat = 4

    /// - Parameters:
    ///   - anchor: 固定する画像の角(スクリーン座標)
    ///   - dragging: 動かしている角
    ///   - live: ドラッグ中(ファイルサイズの再計算を省く)
    func setOutputScale(_ scale: CGFloat, anchor: NSPoint, dragging corner: Corner, live: Bool) {
        outputScale = min(max(scale, CaptureWindow.minScale), CaptureWindow.maxScale)
        let img = displayImageSize
        let origin = NSPoint(x: corner.isRight ? anchor.x : anchor.x - img.width,
                             y: corner.isTop ? anchor.y : anchor.y - img.height)
        setFrame(frameFor(imageSize: img, imageOrigin: origin), display: true)
        layoutContents()
        if live {
            let px = outputPixelSize
            infoBar.setPixelSize(width: px.width, height: px.height)
            infoBar.setScale(outputScale)
        } else {
            refreshInfo()
        }
    }

    /// ドラッグ終了後にファイルサイズなどを更新
    func finishLiveResize() {
        refreshInfo()
        focusImage()
    }

    var outputPixelSize: (width: Int, height: Int) {
        let img = captureView.image
        return (max(1, Int((CGFloat(img.width) * outputScale).rounded())),
                max(1, Int((CGFloat(img.height) * outputScale).rounded())))
    }

    private func promptCustomSize() {
        let original = (captureView.image.width, captureView.image.height)
        let current = outputPixelSize
        let dialog = CustomSizeDialog(originalWidth: original.0, originalHeight: original.1,
                                      currentWidth: current.width)
        let level = NSWindow.Level(rawValue: CaptureWindow.captureLevel.rawValue + 1)
        NSApp.activate(ignoringOtherApps: true)
        if let width = dialog.run(level: level) {
            setOutputScale(CGFloat(width) / CGFloat(original.0))
        } else {
            infoBar.setScale(outputScale) // 選択を元に戻す
            focusImage()
        }
    }

    // MARK: 情報の更新

    func refreshInfo() {
        let px = outputPixelSize
        infoBar.setPixelSize(width: px.width, height: px.height)
        infoBar.setScale(outputScale)
        infoBar.setFormat(OutputSettings.shared.format)
        scheduleFileSizeUpdate()
    }

    /// 現在の設定で書き出した時のファイルサイズをバックグラウンドで計算する
    private func scheduleFileSizeUpdate() {
        fileSizeGeneration += 1
        let generation = fileSizeGeneration
        infoBar.setFileSize(nil)
        let source = captureView.renderedImage()
        let px = outputPixelSize
        let format = OutputSettings.shared.format
        let dpi = 72 * backingScale
        Task { [weak self] in
            let bytes = await Task.detached(priority: .userInitiated) {
                let scaled = ImageEncoder.scaled(source, width: px.width, height: px.height)
                return ImageEncoder.encode(scaled, format: format, dpi: dpi)?.count
            }.value
            guard let self, generation == self.fileSizeGeneration else { return }
            self.infoBar.setFileSize(bytes)
        }
    }

    private func focusImage() {
        makeFirstResponder(captureView)
    }

    // MARK: 書き出し

    /// 書き込み込み・サイズ変更後の画像
    func exportImage() -> CGImage {
        let px = outputPixelSize
        return ImageEncoder.scaled(captureView.renderedImage(), width: px.width, height: px.height)
    }

    func copyOutput() {
        let image = exportImage()
        let format = OutputSettings.shared.format
        let jpeg = format == .png ? nil : ImageEncoder.encode(image, format: format, dpi: 72 * backingScale)
        Clipboard.copy(image, pointSize: pointSize(of: image), jpegData: jpeg)
        infoBar.flash(L("Copied"))
    }

    func saveOutput() {
        let format = OutputSettings.shared.format
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = CaptureWindow.defaultFileName(ext: format.fileExtension)
        NSApp.activate(ignoringOtherApps: true)
        let image = exportImage()
        defer {
            makeKeyAndOrderFront(nil)
            focusImage()
        }
        guard ModalPresenter.run({ panel.runModal() }) == .OK, let url = panel.url else { return }
        do {
            guard let data = ImageEncoder.encode(image, format: format, dpi: 72 * backingScale) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: url, options: .atomic)
            infoBar.flash(L("Saved"))
        } catch {
            let alert = NSAlert(error: error)
            ModalPresenter.run({ alert.runModal() })
        }
    }

    private func pointSize(of image: CGImage) -> NSSize {
        NSSize(width: CGFloat(image.width) / backingScale, height: CGFloat(image.height) / backingScale)
    }

    private static func defaultFileName(ext: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "SnipReel \(f.string(from: Date())).\(ext)"
    }
}

/// 幅・高さ(px)を指定するダイアログ(縦横比は固定)
@MainActor
final class CustomSizeDialog: NSObject, NSTextFieldDelegate {
    private let originalWidth: Int
    private let originalHeight: Int
    private let widthField = NSTextField()
    private let heightField = NSTextField()

    init(originalWidth: Int, originalHeight: Int, currentWidth: Int) {
        self.originalWidth = originalWidth
        self.originalHeight = originalHeight
        super.init()
        widthField.integerValue = currentWidth
        heightField.integerValue = height(forWidth: currentWidth)
    }

    private func height(forWidth w: Int) -> Int {
        max(1, Int((Double(w) * Double(originalHeight) / Double(originalWidth)).rounded()))
    }

    private func width(forHeight h: Int) -> Int {
        max(1, Int((Double(h) * Double(originalWidth) / Double(originalHeight)).rounded()))
    }

    /// OK なら出力幅(px)を返す
    func run(level: NSWindow.Level) -> Int? {
        let alert = NSAlert()
        alert.messageText = L("Custom Size")
        alert.informativeText = L("Original size: %ld × %ld px (aspect ratio is locked)", originalWidth, originalHeight)
        alert.addButton(withTitle: L("OK"))
        alert.addButton(withTitle: L("Cancel"))

        for f in [widthField, heightField] {
            f.delegate = self
            f.alignment = .right
            f.widthAnchor.constraint(equalToConstant: 80).isActive = true
        }
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: L("Width:")), widthField, NSTextField(labelWithString: "px")],
            [NSTextField(labelWithString: L("Height:")), heightField, NSTextField(labelWithString: "px")],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.frame = NSRect(x: 0, y: 0, width: 200, height: 56)
        alert.accessoryView = grid
        alert.window.initialFirstResponder = widthField

        guard ModalPresenter.run({ alert.runModal() }) == .alertFirstButtonReturn else { return nil }
        let maxWidth = originalWidth * 4
        let w = min(max(widthField.integerValue, 1), maxWidth)
        return w
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === widthField, widthField.integerValue > 0 {
            heightField.integerValue = height(forWidth: widthField.integerValue)
        } else if field === heightField, heightField.integerValue > 0 {
            widthField.integerValue = width(forHeight: heightField.integerValue)
        }
    }
}

final class CaptureView: NSView {
    struct Stroke {
        /// 元画像のポイント座標
        var points: [CGPoint]
        var color: NSColor
        var width: CGFloat
    }

    let image: CGImage
    /// 元画像のポイントサイズ
    let baseSize: NSSize
    /// 表示倍率(ウインドウ側から設定)
    var displayScale: CGFloat = 1 { didSet { needsDisplay = true } }
    var onStrokesChanged: (() -> Void)?

    private var strokes: [Stroke] = []
    private var currentStroke: Stroke?
    private let undo = UndoManager()

    init(image: CGImage, baseSize: NSSize) {
        self.image = image
        self.baseSize = baseSize
        super.init(frame: NSRect(origin: .zero, size: baseSize))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var undoManager: UndoManager? { undo }

    private var captureWindow: CaptureWindow? { window as? CaptureWindow }

    // MARK: 描画

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: bounds)
        ctx.saveGState()
        ctx.scaleBy(x: bounds.width / baseSize.width, y: bounds.height / baseSize.height)
        drawStrokes(in: ctx)
        ctx.restoreGState()

        // 画面上で区別しやすいように枠線(保存画像には含まれない)
        NSColor.systemBlue.withAlphaComponent(0.8).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
        drawHandles()
    }

    private func drawStrokes(in ctx: CGContext) {
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for stroke in strokes + (currentStroke.map { [$0] } ?? []) {
            ctx.setStrokeColor(stroke.color.cgColor)
            ctx.setLineWidth(stroke.width)
            ctx.addPath(CaptureView.path(for: stroke.points))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// 中点を使った二次ベジェで滑らかな線にする
    private static func path(for points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: first) // 点(round cap で丸が描かれる)
            return path
        }
        for i in 1..<points.count {
            let prev = points[i - 1], cur = points[i]
            let mid = CGPoint(x: (prev.x + cur.x) / 2, y: (prev.y + cur.y) / 2)
            path.addQuadCurve(to: mid, control: prev)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// 書き込みを含めた元解像度の画像
    func renderedImage() -> CGImage {
        guard !strokes.isEmpty else { return image }
        let w = image.width, h = image.height
        let space = (image.colorSpace?.model == .rgb ? image.colorSpace : nil)
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: CGFloat(w) / baseSize.width, y: CGFloat(h) / baseSize.height)
        drawStrokes(in: ctx)
        return ctx.makeImage() ?? image
    }

    // MARK: マウス操作

    /// ビュー座標 → 元画像のポイント座標
    private func basePoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x / displayScale, y: p.y / displayScale)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            // macOS では Ctrl+クリックも右クリック扱い → メニュー
            showMenu(for: event)
        } else if let corner = corner(at: convert(event.locationInWindow, from: nil)),
                  let win = captureWindow {
            beginResize(corner: corner, window: win)
        } else {
            window?.performDrag(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let r = resizeState, let win = captureWindow else { return }
        let m = NSEvent.mouseLocation
        // 固定した角からマウスまでの距離で倍率を決める(縦横比は固定)
        let w = r.corner.isRight ? m.x - r.anchor.x : r.anchor.x - m.x
        let h = r.corner.isTop ? m.y - r.anchor.y : r.anchor.y - m.y
        var scale = max(w / baseSize.width, h / baseSize.height)
        // 等倍付近は吸着
        if abs(scale - 1) < 0.03 { scale = 1 }
        // 小さくなりすぎないように(短辺 8pt 以上)
        scale = max(scale, 8 / min(baseSize.width, baseSize.height))
        win.setOutputScale(scale, anchor: r.anchor, dragging: r.corner, live: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard resizeState != nil else { return }
        resizeState = nil
        captureWindow?.finishLiveResize()
        needsDisplay = true
    }

    // MARK: 角のドラッグでリサイズ

    private struct ResizeState {
        let corner: CaptureWindow.Corner
        /// 固定される反対側の角(スクリーン座標)
        let anchor: NSPoint
    }

    private var resizeState: ResizeState?
    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    private var handleSize: CGFloat { min(12, bounds.width / 3, bounds.height / 3) }

    private func handleRect(_ corner: CaptureWindow.Corner) -> NSRect {
        let s = handleSize
        return NSRect(x: corner.isRight ? bounds.maxX - s : bounds.minX,
                      y: corner.isTop ? bounds.maxY - s : bounds.minY,
                      width: s, height: s)
    }

    private func corner(at p: NSPoint) -> CaptureWindow.Corner? {
        let all: [CaptureWindow.Corner] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        return all.first { handleRect($0).contains(p) }
    }

    private func beginResize(corner: CaptureWindow.Corner, window: CaptureWindow) {
        let img = window.imageRectOnScreen
        let anchor = NSPoint(x: corner.isRight ? img.minX : img.maxX,
                             y: corner.isTop ? img.minY : img.maxY)
        resizeState = ResizeState(corner: corner, anchor: anchor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero,
                               options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
        if resizeState == nil { NSCursor.arrow.set() }
    }

    override func mouseMoved(with event: NSEvent) {
        guard resizeState == nil else { return }
        if let c = corner(at: convert(event.locationInWindow, from: nil)) {
            CaptureView.resizeCursor(for: c).set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private static func resizeCursor(for corner: CaptureWindow.Corner) -> NSCursor {
        if #available(macOS 15.0, *) {
            let pos: NSCursor.FrameResizePosition
            switch corner {
            case .topLeft: pos = .topLeft
            case .topRight: pos = .topRight
            case .bottomLeft: pos = .bottomLeft
            case .bottomRight: pos = .bottomRight
            }
            return NSCursor.frameResize(position: pos, directions: .all)
        }
        return .crosshair
    }

    private func drawHandles() {
        guard isHovering || resizeState != nil else { return }
        let all: [CaptureWindow.Corner] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        for c in all {
            let r = handleRect(c).insetBy(dx: 2, dy: 2)
            let path = NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5)
            NSColor.white.setFill()
            path.fill()
            NSColor.systemBlue.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            let settings = PenSettings.shared
            // 画面上で選んだ太さに見えるよう、表示倍率で割る
            currentStroke = Stroke(points: [basePoint(event)], color: settings.color,
                                   width: settings.width / displayScale)
            needsDisplay = true
        } else {
            showMenu(for: event)
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard currentStroke != nil else { return }
        let p = basePoint(event)
        if let last = currentStroke?.points.last,
           hypot(p.x - last.x, p.y - last.y) * displayScale < 0.5 { return }
        currentStroke?.points.append(p)
        needsDisplay = true
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let stroke = currentStroke else { return }
        currentStroke = nil
        setStrokes(strokes + [stroke], actionName: L("Drawing"))
    }

    // MARK: 取り消し

    private func setStrokes(_ new: [Stroke], actionName: String) {
        let old = strokes
        undo.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.setStrokes(old, actionName: actionName) }
        }
        undo.setActionName(actionName)
        strokes = new
        needsDisplay = true
        onStrokesChanged?()
    }

    @objc func undoAction(_ sender: Any?) { if undo.canUndo { undo.undo() } }
    @objc func redoAction(_ sender: Any?) { if undo.canRedo { undo.redo() } }
    @objc func clearStrokes(_ sender: Any?) {
        guard !strokes.isEmpty else { return }
        setStrokes([], actionName: L("Clear All"))
    }

    // MARK: キーボード

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.isKeyWindow == true else { return false }
        let flags = event.modifierFlags.intersection(Shortcut.relevantModifiers)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (flags, key) {
        case ([.command], "c"): copyAction(nil); return true
        case ([.command], "s"): saveAction(nil); return true
        case ([.command], "z"): undoAction(nil); return true
        case ([.command, .shift], "z"): redoAction(nil); return true
        case ([.command], "w"): window?.close(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            window?.close()
        } else {
            super.keyDown(with: event)
        }
    }

    @objc func copyAction(_ sender: Any?) { captureWindow?.copyOutput() }
    @objc func saveAction(_ sender: Any?) { captureWindow?.saveOutput() }

    // MARK: 右クリックメニュー

    private func showMenu(for event: NSEvent) {
        window?.makeKey()
        NSMenu.popUpContextMenu(buildMenu(), with: event, for: self)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        func item(_ title: String, _ action: Selector, _ key: String = "",
                  _ mods: NSEvent.ModifierFlags = [.command], enabled: Bool = true) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = self
            i.isEnabled = enabled
            return i
        }

        menu.addItem(item(L("Copy"), #selector(copyAction(_:)), "c"))
        menu.addItem(item(L("Save…"), #selector(saveAction(_:)), "s"))
        menu.addItem(.separator())

        let undoTitle = undo.canUndo ? L("Undo %@", undo.undoActionName) : L("Undo")
        let redoTitle = undo.canRedo ? L("Redo %@", undo.redoActionName) : L("Redo")
        menu.addItem(item(undoTitle, #selector(undoAction(_:)), "z", enabled: undo.canUndo))
        menu.addItem(item(redoTitle, #selector(redoAction(_:)), "z", [.command, .shift], enabled: undo.canRedo))
        menu.addItem(item(L("Clear All Drawings"), #selector(clearStrokes(_:)), enabled: !strokes.isEmpty))
        menu.addItem(.separator())

        let settings = PenSettings.shared

        // 色
        let colorMenu = NSMenu()
        colorMenu.autoenablesItems = false
        var matchedPreset = false
        for (index, preset) in PenSettings.presetColors.enumerated() {
            let i = item(L(preset.name), #selector(selectColor(_:)))
            i.tag = index
            i.image = CaptureView.swatch(preset.color)
            if PenSettings.isSameColor(preset.color, settings.color) {
                i.state = .on
                matchedPreset = true
            }
            colorMenu.addItem(i)
        }
        colorMenu.addItem(.separator())
        let custom = item(L("Other Color…"), #selector(showColorPanel(_:)))
        if !matchedPreset {
            custom.state = .on
            custom.image = CaptureView.swatch(settings.color)
        }
        colorMenu.addItem(custom)
        let colorItem = NSMenuItem(title: L("Pencil Color"), action: nil, keyEquivalent: "")
        colorItem.image = CaptureView.swatch(settings.color)
        colorItem.submenu = colorMenu
        menu.addItem(colorItem)

        // 太さ
        let widthMenu = NSMenu()
        widthMenu.autoenablesItems = false
        for (index, preset) in PenSettings.presetWidths.enumerated() {
            let i = item(L(preset.name), #selector(selectWidth(_:)))
            i.tag = index
            i.state = preset.width == settings.width ? .on : .off
            widthMenu.addItem(i)
        }
        let widthItem = NSMenuItem(title: L("Pencil Width"), action: nil, keyEquivalent: "")
        widthItem.submenu = widthMenu
        menu.addItem(widthItem)

        menu.addItem(.separator())
        let hint = NSMenuItem(title: L("Ctrl + right-drag to draw"), action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        let close = item(L("Close"), #selector(closeAction(_:)), "\u{1b}", [])
        menu.addItem(close)
        return menu
    }

    @objc private func selectColor(_ sender: NSMenuItem) {
        PenSettings.shared.color = PenSettings.presetColors[sender.tag].color
    }

    @objc private func selectWidth(_ sender: NSMenuItem) {
        PenSettings.shared.width = PenSettings.presetWidths[sender.tag].width
    }

    @objc private func showColorPanel(_ sender: Any?) {
        let panel = NSColorPanel.shared
        panel.color = PenSettings.shared.color
        panel.showsAlpha = true
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        PenSettings.shared.color = sender.color
    }

    @objc private func closeAction(_ sender: Any?) {
        window?.close()
    }

    private static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            color.setFill()
            path.fill()
            NSColor.gray.setStroke()
            path.lineWidth = 0.5
            path.stroke()
            return true
        }
    }
}

enum Clipboard {
    /// - Parameter jpegData: JPEG 形式を選んでいる場合、対応アプリ向けに JPEG も載せる
    static func copy(_ image: CGImage, pointSize: NSSize, jpegData: Data? = nil) {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = pointSize // Retina の DPI 情報を保持
        let pb = NSPasteboard.general
        pb.clearContents()
        let jpegType = NSPasteboard.PasteboardType(UTType.jpeg.identifier)
        var types: [NSPasteboard.PasteboardType] = []
        if jpegData != nil { types.append(jpegType) }
        types += [.png, .tiff]
        pb.declareTypes(types, owner: nil)
        if let jpegData { pb.setData(jpegData, forType: jpegType) }
        if let png = rep.representation(using: .png, properties: [:]) { pb.setData(png, forType: .png) }
        if let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
    }
}
