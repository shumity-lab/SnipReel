import AppKit

/// 録画範囲の周りに出す赤い枠(カウントダウンの数字も表示)。動画には写らない
final class RecordingFrameWindow: NSWindow {
    static let margin: CGFloat = 4
    private let frameView = RecordingFrameView()

    init(region: NSRect) {
        super.init(contentRect: region.insetBy(dx: -RecordingFrameWindow.margin, dy: -RecordingFrameWindow.margin),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = frameView
    }

    var countdown: Int? {
        get { frameView.countdown }
        set { frameView.countdown = newValue; frameView.needsDisplay = true }
    }

    var isPaused = false {
        didSet { frameView.isPaused = isPaused; frameView.needsDisplay = true }
    }
}

private final class RecordingFrameView: NSView {
    var countdown: Int?
    var isPaused = false

    override func draw(_ dirtyRect: NSRect) {
        let m = RecordingFrameWindow.margin
        let region = bounds.insetBy(dx: m, dy: m)
        let border = NSBezierPath(rect: region.insetBy(dx: -1.5, dy: -1.5))
        border.lineWidth = 2
        if countdown != nil || isPaused {
            border.setLineDash([6, 4], count: 2, phase: 0)
        }
        (isPaused ? NSColor.systemOrange : NSColor.systemRed).setStroke()
        border.stroke()

        guard let n = countdown else { return }
        let text = "\(n)" as NSString
        let size = min(96, region.height * 0.5, region.width * 0.5)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let ts = text.size(withAttributes: attrs)
        let d = max(ts.width, ts.height) + size * 0.4
        let circle = NSRect(x: region.midX - d / 2, y: region.midY - d / 2, width: d, height: d)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(ovalIn: circle).fill()
        text.draw(at: NSPoint(x: region.midX - ts.width / 2, y: region.midY - ts.height / 2), withAttributes: attrs)
    }
}

/// 録画の操作バー(経過時間・システム音声・マイク・一時停止・停止)
/// 録画中のアプリからフォーカスを奪わないよう、アクティブにならないパネルにする
final class RecordingControlPanel: NSPanel {
    var onToggleSystemAudio: (() -> Void)?
    var onToggleMicrophone: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onStop: (() -> Void)?

    private let dot = NSImageView()
    private let timeLabel = NSTextField(labelWithString: "")
    private var systemButton: NSButton!
    private var micButton: NSButton!
    private var pauseButton: NSButton!
    private var stopButton: NSButton!

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 36),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        buildUI()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func button(_ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(), target: self, action: action)
        b.isBordered = false
        b.contentTintColor = .white
        b.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        b.widthAnchor.constraint(equalToConstant: 26).isActive = true
        b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return b
    }

    private func buildUI() {
        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.appearance = NSAppearance(named: .vibrantDark)
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 10
        bg.layer?.masksToBounds = true

        dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        dot.symbolConfiguration = .init(pointSize: 9, weight: .regular)
        dot.contentTintColor = .systemRed
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timeLabel.textColor = .white
        timeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true

        systemButton = button(#selector(systemTapped))
        micButton = button(#selector(micTapped))
        pauseButton = button(#selector(pauseTapped))
        stopButton = button(#selector(stopTapped))
        stopButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: L("Stop"))
        stopButton.contentTintColor = .systemRed
        stopButton.toolTip = L("Stop recording")

        let sep = NSBox()
        sep.boxType = .separator
        sep.heightAnchor.constraint(equalToConstant: 18).isActive = true

        let stack = NSStackView(views: [dot, timeLabel, sep, systemButton, micButton, pauseButton, stopButton])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
        ])
        contentView = bg
        let width = ceil(stack.fittingSize.width)
        setContentSize(NSSize(width: width, height: 36))
    }

    /// - Parameters:
    ///   - status: 経過時間や「まもなく開始」などの表示
    ///   - phase: 操作できるボタンの切り替えに使う
    func update(status: String, systemAudio: Bool, microphone: Bool,
                isPaused: Bool, isBusy: Bool, isCountdown: Bool) {
        timeLabel.stringValue = status
        dot.contentTintColor = isPaused ? .systemOrange : .systemRed

        systemButton.image = NSImage(systemSymbolName: systemAudio ? "speaker.wave.2.fill" : "speaker.slash.fill",
                                     accessibilityDescription: nil)
        systemButton.contentTintColor = systemAudio ? .white : .secondaryLabelColor
        systemButton.toolTip = systemAudio ? L("System audio: On") : L("System audio: Off")

        micButton.image = NSImage(systemSymbolName: microphone ? "mic.fill" : "mic.slash.fill",
                                  accessibilityDescription: nil)
        micButton.contentTintColor = microphone ? .white : .secondaryLabelColor
        micButton.toolTip = microphone ? L("Microphone: On") : L("Microphone: Off")

        pauseButton.image = NSImage(systemSymbolName: isPaused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
        pauseButton.toolTip = isPaused ? L("Resume") : L("Pause")
        pauseButton.isHidden = isCountdown
        stopButton.toolTip = isCountdown ? L("Cancel") : L("Stop recording")

        for b in [systemButton, micButton, pauseButton, stopButton] { b?.isEnabled = !isBusy }
    }

    /// 録画範囲の下(入らなければ上、それも無理なら範囲の内側下部)に置く
    func place(near region: NSRect, on screen: NSScreen) {
        let v = screen.visibleFrame
        let s = frame.size
        var x = region.midX - s.width / 2
        x = min(max(x, v.minX + 8), v.maxX - s.width - 8)
        let gap: CGFloat = 10
        let y: CGFloat
        if region.minY - gap - s.height >= v.minY {
            y = region.minY - gap - s.height
        } else if region.maxY + gap + s.height <= v.maxY {
            y = region.maxY + gap
        } else {
            y = max(region.minY, v.minY) + 16
        }
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    @objc private func systemTapped() { onToggleSystemAudio?() }
    @objc private func micTapped() { onToggleMicrophone?() }
    @objc private func pauseTapped() { onTogglePause?() }
    @objc private func stopTapped() { onStop?() }
}

/// カウントダウン → 録画 → 終了 までの流れを管理する
@MainActor
final class RecordingController {
    enum Phase { case countdown, starting, recording, finishing }

    /// 結果: 動画ファイル(キャンセル時は nil)・エラー
    var onFinished: ((RecordingController, URL?, Error?) -> Void)?
    var onTick: ((TimeInterval) -> Void)?

    let region: NSRect // グローバル座標
    private let localRect: CGRect
    private let screen: NSScreen
    private let frameWindow: RecordingFrameWindow
    private let panel = RecordingControlPanel()
    private let settings = RecordingSettings.shared
    private var recorder: ScreenRecorder?
    private(set) var phase: Phase = .countdown
    private var countdown = 3
    private var timer: Timer?
    private var busy = false
    private var stopRequested = false

    init(screen: NSScreen, localRect: CGRect) {
        self.screen = screen
        self.localRect = localRect
        region = NSRect(x: screen.frame.minX + localRect.minX, y: screen.frame.minY + localRect.minY,
                        width: localRect.width, height: localRect.height)
        frameWindow = RecordingFrameWindow(region: region)
        panel.onStop = { [weak self] in self?.stop() }
        panel.onTogglePause = { [weak self] in self?.togglePause() }
        panel.onToggleSystemAudio = { [weak self] in self?.toggleAudio(system: true) }
        panel.onToggleMicrophone = { [weak self] in self?.toggleAudio(system: false) }
    }

    func begin() {
        frameWindow.countdown = countdown
        frameWindow.orderFrontRegardless()
        refreshPanel()
        panel.place(near: region, on: screen)
        panel.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.countdownTick() }
        }
    }

    private func countdownTick() {
        countdown -= 1
        if countdown > 0 {
            frameWindow.countdown = countdown
            refreshPanel()
        } else {
            timer?.invalidate()
            timer = nil
            frameWindow.countdown = nil
            Task { await startRecording() }
        }
    }

    private func startRecording() async {
        phase = .starting
        busy = true
        refreshPanel()
        if settings.microphone, !(await MicrophonePermission.request()) {
            settings.microphone = false
            showMicrophonePermissionAlert()
        }
        do {
            let r = try ScreenRecorder(systemAudio: settings.systemAudio, microphone: settings.microphone)
            r.onUnexpectedStop = { [weak self] _ in self?.stop() }
            recorder = r
            try await r.start(rect: localRect, on: screen)
        } catch {
            await recorder?.cancel()
            teardown()
            onFinished?(self, nil, error)
            return
        }
        phase = .recording
        busy = false
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPanel() }
        }
        refreshPanel()
        if stopRequested { stop() }
    }

    /// 停止(カウントダウン中ならキャンセル)
    func stop() {
        switch phase {
        case .countdown:
            teardown()
            onFinished?(self, nil, nil)
        case .starting:
            stopRequested = true
        case .recording:
            guard !busy else { stopRequested = true; return }
            phase = .finishing
            busy = true
            refreshPanel()
            Task {
                do {
                    let url = try await recorder!.finish()
                    teardown()
                    onFinished?(self, url, nil)
                } catch {
                    await recorder?.cancel()
                    teardown()
                    onFinished?(self, nil, error)
                }
            }
        case .finishing:
            break
        }
    }

    private func togglePause() {
        guard phase == .recording, !busy, let recorder else { return }
        busy = true
        refreshPanel()
        Task {
            if recorder.isPaused {
                do { try recorder.resume() } catch { NSSound.beep() }
            } else {
                await recorder.pause()
            }
            busy = false
            frameWindow.isPaused = recorder.isPaused
            refreshPanel()
            if stopRequested { stop() }
        }
    }

    private func toggleAudio(system: Bool) {
        guard !busy else { return }
        var sys = recorder?.systemAudio ?? settings.systemAudio
        var mic = recorder?.microphone ?? settings.microphone
        if system { sys.toggle() } else { mic.toggle() }

        busy = true
        refreshPanel()
        Task {
            if !system, mic, !(await MicrophonePermission.request()) {
                showMicrophonePermissionAlert()
                busy = false
                refreshPanel()
                return
            }
            settings.systemAudio = sys
            settings.microphone = mic
            if phase == .recording, let recorder {
                do { try await recorder.setAudio(system: sys, microphone: mic) } catch { NSSound.beep() }
            }
            busy = false
            refreshPanel()
            if stopRequested { stop() }
        }
    }

    private func refreshPanel() {
        let status: String
        switch phase {
        case .countdown: status = L("Starting in %ld…", countdown)
        case .starting: status = L("Starting…")
        case .finishing: status = L("Saving…")
        case .recording: status = (recorder?.isPaused == true ? L("Paused") + " " : "") + Self.format(recorder?.elapsed ?? 0)
        }
        panel.update(status: status,
                     systemAudio: recorder?.systemAudio ?? settings.systemAudio,
                     microphone: recorder?.microphone ?? settings.microphone,
                     isPaused: recorder?.isPaused == true && phase == .recording,
                     isBusy: busy, isCountdown: phase == .countdown)
        onTick?(recorder?.elapsed ?? 0)
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }

    private func teardown() {
        timer?.invalidate()
        timer = nil
        frameWindow.orderOut(nil)
        panel.orderOut(nil)
    }

    private func showMicrophonePermissionAlert() {
        let alert = NSAlert()
        alert.messageText = L("Microphone permission is required")
        alert.informativeText = L("Allow SnipReel in System Settings → Privacy & Security → Microphone.")
        alert.addButton(withTitle: L("Open System Settings"))
        alert.addButton(withTitle: L("Close"))
        NSApp.activate(ignoringOtherApps: true)
        if ModalPresenter.run({ alert.runModal() }) == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
