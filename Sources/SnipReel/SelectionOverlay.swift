import AppKit

enum SelectionMode {
    case capture
    /// 録画: クリックだけで画面全体を選べる
    case record
}

/// 範囲選択用の全画面オーバーレイ(ディスプレイごとに 1 枚)
final class SelectionOverlayWindow: NSWindow {
    let targetScreen: NSScreen

    init(screen: NSScreen, mode: SelectionMode, onFinish: @escaping (SelectionOverlayWindow, CGRect?) -> Void) {
        targetScreen = screen
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.mode = mode
        view.onFinish = { [unowned self] rect in onFinish(self, rect) }
        contentView = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class SelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    var mode: SelectionMode = .capture
    private var startPoint: CGPoint?
    private var selection: CGRect?
    private var finished = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = clamp(convert(event.locationInWindow, from: nil))
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = startPoint else { return }
        let p = clamp(convert(event.locationInWindow, from: nil))
        selection = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let sel = selection?.integral, sel.width >= 3, sel.height >= 3 else {
            if mode == .record, startPoint != nil {
                finish(bounds) // クリックだけ → 画面全体を録画
                return
            }
            // クリックだけ(ほぼサイズ 0)はやり直し扱い
            startPoint = nil
            selection = nil
            needsDisplay = true
            return
        }
        finish(sel)
    }

    override func rightMouseDown(with event: NSEvent) { finish(nil) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish(nil) } // Esc
    }

    private func finish(_ rect: CGRect?) {
        guard !finished else { return }
        finished = true
        onFinish?(rect)
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        if let sel = selection {
            dim.append(NSBezierPath(rect: sel))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.3).setFill()
        dim.fill()

        guard let sel = selection else {
            drawHint()
            return
        }
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()

        // サイズ表示(ピクセル)
        let scale = window?.backingScaleFactor ?? 2
        let text = "\(Int(sel.width * scale)) × \(Int(sel.height * scale))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        var origin = CGPoint(x: sel.minX, y: sel.maxY + 4)
        if origin.y + size.height + 4 > bounds.maxY { origin.y = sel.maxY - size.height - 8 }
        origin.x = min(origin.x, bounds.maxX - size.width - 8)
        let bg = NSRect(x: origin.x, y: origin.y, width: size.width + 8, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 3, yRadius: 3).fill()
        text.draw(at: CGPoint(x: bg.minX + 4, y: bg.minY + 2), withAttributes: attrs)
    }

    private func drawHint() {
        let text = (mode == .record
            ? L("Drag to select an area to record / Click to record the full screen / Esc to cancel")
            : L("Drag to select an area / Esc to cancel")) as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        let bg = NSRect(x: bounds.midX - size.width / 2 - 12, y: bounds.midY - size.height / 2 - 6,
                        width: size.width + 24, height: size.height + 12)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 8, yRadius: 8).fill()
        text.draw(at: CGPoint(x: bg.minX + 12, y: bg.minY + 6), withAttributes: attrs)
    }
}
