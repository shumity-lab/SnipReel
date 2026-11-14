import AVFoundation
import ScreenCaptureKit

/// 録画の音声設定(次回も同じ設定で始まるよう記憶する)
@MainActor
final class RecordingSettings {
    static let shared = RecordingSettings()
    private let d = UserDefaults.standard

    var systemAudio: Bool {
        get { d.object(forKey: "recordSystemAudio") as? Bool ?? true }
        set { d.set(newValue, forKey: "recordSystemAudio") }
    }
    var microphone: Bool {
        get { d.object(forKey: "recordMicrophone") as? Bool ?? false }
        set { d.set(newValue, forKey: "recordMicrophone") }
    }
}

enum MicrophonePermission {
    static func request() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}

/// 録画ファイルの置き場所(~/Library/Caches/<bundle id>/Recordings)
enum RecordingFiles {
    static var root: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "SnipReel")
            .appendingPathComponent("Recordings")
    }

    static func newWorkDirectory() throws -> URL {
        let dir = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 1 日以上前の一時ファイルを削除する(コピーしたファイルを貼り付けられるよう、すぐには消さない)
    static func cleanUpOldFiles() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let limit = Date().addingTimeInterval(-24 * 60 * 60)
        for item in items {
            let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let date, date < limit { try? fm.removeItem(at: item) }
        }
    }
}

enum RecordingError: LocalizedError {
    case nothingRecorded
    case exportFailed
    /// 結合に失敗した。録画したファイルは folder に残してある
    case composeFailed(folder: URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .nothingRecorded: return L("Nothing was recorded.")
        case .exportFailed: return L("Failed to create the video file.")
        case let .composeFailed(folder, underlying):
            return L("Failed to create the video file.") + "\n" + underlying.localizedDescription + "\n\n"
                + L("The recorded files were kept in this folder (they will be deleted automatically after a day):")
                + "\n" + folder.path
        }
    }
}

/// ScreenCaptureKit で指定範囲を録画する。
/// 一時停止・音声の切り替えのたびに録画ファイルを区切り(セグメント)、終了時に 1 本の MP4 にまとめる。
@MainActor
final class ScreenRecorder: NSObject {
    private(set) var systemAudio: Bool
    private(set) var microphone: Bool
    /// 録画中にストリームが止まった場合などに呼ばれる
    var onUnexpectedStop: ((Error) -> Void)?

    private var stream: SCStream?
    private let config = SCStreamConfiguration()
    private var output: SCRecordingOutput?
    private var outputURL: URL?
    private var segmentStart: Date?
    private var accumulated: TimeInterval = 0
    private var segments: [URL] = []
    private var segmentIndex = 0
    private var finishContinuation: CheckedContinuation<Void, Never>?
    /// 完了を待っている録画出力(古い出力の通知やタイムアウトで別の待ちを解かないように区別する)
    /// 保持しておくので、待ちが終わるまで同じアドレスが別の出力に再利用されることはない
    private var pendingOutput: SCRecordingOutput?
    private var pendingToken = 0
    private let workDir: URL

    var isPaused: Bool { output == nil }
    var elapsed: TimeInterval { accumulated + (segmentStart.map { Date().timeIntervalSince($0) } ?? 0) }

    init(systemAudio: Bool, microphone: Bool) throws {
        self.systemAudio = systemAudio
        self.microphone = microphone
        workDir = try RecordingFiles.newWorkDirectory()
    }

    /// - Parameter rect: スクリーン内のローカル座標(ポイント、左下原点)
    func start(rect: CGRect, on screen: NSScreen) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let displayID = screen.displayID,
              let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }
        // 録画枠や操作バーなど、自分のウインドウは写さない
        let pid = ProcessInfo.processInfo.processIdentifier
        let me = content.applications.filter { $0.processID == pid }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        let scale = screen.backingScaleFactor
        func even(_ v: CGFloat) -> Int { max(2, Int(v.rounded()) & ~1) } // H.264 は偶数サイズ
        config.sourceRect = CGRect(x: rect.minX, y: screen.frame.height - rect.maxY,
                                   width: rect.width, height: rect.height)
        config.width = even(rect.width * scale)
        config.height = even(rect.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true
        config.colorSpaceName = CGColorSpace.sRGB
        config.capturesAudio = systemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.captureMicrophone = microphone

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream
        try await stream.startCapture()
        try startSegment()
    }

    func pause() async {
        await stopSegment()
    }

    func resume() throws {
        guard isPaused else { return }
        try startSegment()
    }

    /// 録画中に音声の設定を変える(区切りを入れて設定を更新)
    func setAudio(system: Bool, microphone mic: Bool) async throws {
        guard let stream else { return }
        let wasRecording = !isPaused
        if wasRecording { await stopSegment() }
        config.capturesAudio = system
        config.captureMicrophone = mic
        try await stream.updateConfiguration(config)
        systemAudio = system
        microphone = mic
        if wasRecording { try startSegment() }
    }

    /// 録画を終えて、1 本の MP4 にまとめたファイルを返す
    func finish() async throws -> URL {
        await stopSegment()
        if let stream { try? await stream.stopCapture() }
        stream = nil
        let out = workDir.appendingPathComponent("SnipReel.mp4")
        do {
            return try await RecordingComposer.compose(segments, output: out)
        } catch RecordingError.nothingRecorded {
            try? FileManager.default.removeItem(at: workDir)
            throw RecordingError.nothingRecorded
        } catch {
            // 録画したファイルは消さずに残す
            throw RecordingError.composeFailed(folder: workDir, underlying: error)
        }
    }

    /// 録画を破棄する
    func cancel() async {
        await stopSegment()
        if let stream { try? await stream.stopCapture() }
        stream = nil
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: セグメント

    private func startSegment() throws {
        guard let stream else { return }
        segmentIndex += 1
        let url = workDir.appendingPathComponent("segment-\(segmentIndex).mp4")
        let rc = SCRecordingOutputConfiguration()
        rc.outputURL = url
        rc.outputFileType = .mp4
        rc.videoCodecType = .h264
        let out = SCRecordingOutput(configuration: rc, delegate: self)
        try stream.addRecordingOutput(out)
        output = out
        outputURL = url
        segmentStart = Date()
    }

    private func stopSegment() async {
        guard let stream, let out = output, let url = outputURL else { return }
        if let s = segmentStart { accumulated += Date().timeIntervalSince(s) }
        segmentStart = nil
        output = nil
        outputURL = nil
        pendingToken += 1
        let token = pendingToken
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            finishContinuation = c
            pendingOutput = out
            do {
                try stream.removeRecordingOutput(out)
            } catch {
                resumeFinish()
                return
            }
            // 念のため、完了通知が来なくても先に進む(この待ちがまだ続いている場合だけ)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.pendingToken == token else { return }
                self.resumeFinish()
            }
        }
        if FileManager.default.fileExists(atPath: url.path) { segments.append(url) }
    }

    private func resumeFinish() {
        pendingOutput = nil
        finishContinuation?.resume()
        finishContinuation = nil
    }

    private func isPending(_ out: SCRecordingOutput) -> Bool {
        pendingOutput === out
    }
}

extension ScreenRecorder: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        let box = UncheckedBox(recordingOutput)
        Task { @MainActor in if self.isPending(box.value) { self.resumeFinish() } }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        let box = UncheckedBox(recordingOutput)
        Task { @MainActor in
            if self.isPending(box.value) {
                self.resumeFinish()
            } else if self.output === box.value {
                self.onUnexpectedStop?(error)
            }
        }
    }
}

extension ScreenRecorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.onUnexpectedStop?(error) }
    }
}

/// 録画セグメントをつなぎ、音声(システム音声・マイク)を 1 トラックに混ぜた MP4 を作る
enum RecordingComposer {
    private struct Segment {
        let url: URL
        /// トラックは asset を弱参照しかしないので、書き出しが終わるまで asset を保持しておく
        let asset: AVURLAsset
        let video: AVAssetTrack
        let audio: [AVAssetTrack]
        let range: CMTimeRange
    }

    static func compose(_ urls: [URL], output: URL) async throws -> URL {
        var segments: [Segment] = []
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let video = try? await asset.loadTracks(withMediaType: .video).first,
                  let range = try? await video.load(.timeRange),
                  range.duration.seconds > 0 else { continue } // 短すぎて中身がないセグメントは捨てる
            let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            segments.append(Segment(url: url, asset: asset, video: video, audio: audio, range: range))
        }
        guard let first = segments.first else { throw RecordingError.nothingRecorded }

        // 1 本だけ・音声トラックが 1 つ以下なら、そのまま使う
        if segments.count == 1 && first.audio.count <= 1 {
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.moveItem(at: first.url, to: output)
            return output
        }

        let comp = AVMutableComposition()
        guard let videoTrack = comp.addMutableTrack(withMediaType: .video,
                                                    preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw RecordingError.exportFailed }
        videoTrack.preferredTransform = (try? await first.video.load(.preferredTransform)) ?? .identity
        var audioTracks: [AVMutableCompositionTrack] = []
        var cursor = CMTime.zero
        for seg in segments {
            try videoTrack.insertTimeRange(seg.range, of: seg.video, at: cursor)
            for (i, track) in seg.audio.enumerated() {
                while audioTracks.count <= i {
                    guard let t = comp.addMutableTrack(withMediaType: .audio,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid)
                    else { throw RecordingError.exportFailed }
                    audioTracks.append(t)
                }
                guard let audioRange = try? await track.load(.timeRange) else { continue }
                let r = audioRange.intersection(seg.range)
                if r.duration > .zero {
                    try audioTracks[i].insertTimeRange(r, of: track, at: cursor + (r.start - seg.range.start))
                }
            }
            cursor = cursor + seg.range.duration
        }

        try? FileManager.default.removeItem(at: output)
        try await write(comp, video: videoTrack, audio: audioTracks, to: output)
        for seg in segments { try? FileManager.default.removeItem(at: seg.url) }
        return output
    }

    /// 合成した動画を書き出す。複数の音声トラック(システム音声・マイク)は 1 本のステレオにミックスする
    private static func write(_ comp: AVComposition, video: AVCompositionTrack,
                              audio: [AVCompositionTrack], to output: URL) async throws {
        let size = try await video.load(.naturalSize)
        let reader = try AVAssetReader(asset: comp)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)

        // 映像: デコード → H.264 で再エンコード
        let videoOut = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        videoOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut) else { throw RecordingError.exportFailed }
        reader.add(videoOut)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        videoIn.transform = video.preferredTransform
        guard writer.canAdd(videoIn) else { throw RecordingError.exportFailed }
        writer.add(videoIn)

        // 音声: 全トラックをミックス → AAC ステレオ
        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = [(videoOut, videoIn)]
        if !audio.isEmpty {
            let audioOut = AVAssetReaderAudioMixOutput(audioTracks: audio, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            guard reader.canAdd(audioOut) else { throw RecordingError.exportFailed }
            reader.add(audioOut)
            let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            guard writer.canAdd(audioIn) else { throw RecordingError.exportFailed }
            writer.add(audioIn)
            pairs.append((audioOut, audioIn))
        }

        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? RecordingError.exportFailed
        }
        writer.startSession(atSourceTime: .zero)

        // 各トラックを並行してコピー
        await withTaskGroup(of: Void.self) { group in
            for (index, pair) in pairs.enumerated() {
                let box = UncheckedBox((pair.0, pair.1))
                group.addTask {
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                        let queue = DispatchQueue(label: "SnipReel.compose.\(index)")
                        box.value.1.requestMediaDataWhenReady(on: queue) {
                            let (out, input) = box.value
                            while input.isReadyForMoreMediaData {
                                if let sample = out.copyNextSampleBuffer() {
                                    if !input.append(sample) {
                                        input.markAsFinished()
                                        c.resume()
                                        return
                                    }
                                } else {
                                    input.markAsFinished()
                                    c.resume()
                                    return
                                }
                            }
                        }
                    }
                }
            }
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? RecordingError.exportFailed
        }
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? RecordingError.exportFailed
        }
    }
}

/// Sendable でない AVFoundation のオブジェクトを、1 つのキューでだけ使う前提で渡すための箱
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
