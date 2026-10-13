import SwiftUI
import AppKit
import AVFoundation
import Observation
import BirdLockCore
import UniformTypeIdentifiers

enum Phase: Equatable {
    case empty
    case importing
    case analyzing(stage: String, progress: Double)
    case ready
    case failed(String)
}

enum ViewMode: String, CaseIterable, Identifiable {
    case output, source
    var id: String { rawValue }
    var title: String { self == .output ? "成片预览" : "原图+识别" }
}

enum SourceTool: String, CaseIterable, Identifiable {
    case none, fixEye, pickBird
    var id: String { rawValue }
}

struct ExportState: Equatable {
    var running = false
    var progress = 0.0
    var message = ""
    var outputURL: URL? = nil
}

/// Sharp crop of the original shown in the zoomed source view.
struct SourceDetail {
    var image: CGImage
    var rect: CGRect      // source px
    var frame: Int
}

@MainActor
@Observable
final class AppState {
    // Input
    var frames: [SourceFrame] = []
    var segments: [BurstSegment] = []
    var segmentIndex = 0
    var phase: Phase = .empty
    var analysis: SequenceAnalysis?
    var analysisStarted = Date()

    // Settings (persisted)
    var composition = Composition() { didSet { settingsChanged() } }
    var look = LookSettings() { didSet { settingsChanged() } }
    var exportSettings = ExportSettings() { didSet { settingsChanged() } }
    var selection = FrameSelection() { didSet { settingsChanged() } }
    var presetID: String? = "lead"
    var audio = AudioSettings() { didSet { audioChanged(from: oldValue) } }
    var watermark = WatermarkSettings() { didSet { watermarkChanged(from: oldValue) } }

    // Music & watermark
    var audioOverview: AudioMixer.Overview?
    var audioMessage: String?
    var previewAudio = true
    var watermarkImage: CGImage?

    // Preview
    var job: RenderJob?
    var viewMode: ViewMode = .output
    var sourceTool: SourceTool = .none
    var currentFrame = 0          // source frame index
    var playheadOutput = 0        // index into job.outputFrames while playing
    var isPlaying = false
    var previewImage: CGImage?
    var sourceImage: CGImage?
    var sourceDetail: SourceDetail?
    /// 1 = whole photo; larger values zoom in and follow the bird's head
    var sourceZoom: Double = 1
    var exportState = ExportState()
    var showExportSheet = false
    var loopPlayback = true

    let engine = PreviewEngine()
    private var models: BirdModels?
    private var analysisTask: Task<Void, Never>?
    private var cancelFlag = CancelFlag()
    private var importGeneration = 0
    private var rebuildWork: DispatchWorkItem?
    private var playTimer: Timer?
    private var saveWork: DispatchWorkItem?
    private var settingsSaveWork: DispatchWorkItem?
    private var audioPlayer: AVPlayer?
    private var audioBuildTask: Task<Void, Never>?
    private var audioOverviewTask: Task<Void, Never>?

    init() {
        loadSettings()
    }

    // MARK: - Import & analysis

    func importURLs(_ urls: [URL]) {
        stop()
        analysisTask?.cancel(); cancelFlag.cancel()
        importGeneration += 1
        let generation = importGeneration
        phase = .importing
        analysis = nil; job = nil; previewImage = nil; sourceImage = nil; sourceDetail = nil
        Task.detached(priority: .userInitiated) {
            let all = FrameImporter.importFrames(urls)
            let segs = FrameImporter.segments(all)
            await MainActor.run {
                // a newer import started meanwhile
                guard generation == self.importGeneration else { return }
                self.segmentIndex = 0
                self.frames = all
                self.segments = segs
                self.currentFrame = 0
                guard !all.isEmpty else { self.phase = .failed("没有找到 JPG / HEIF 图片"); return }
                // choose the longest burst by default
                self.segmentIndex = segs.indices.max { segs[$0].range.count < segs[$1].range.count } ?? 0
                self.startAnalysis()
            }
        }
    }

    var currentFrames: [SourceFrame] {
        guard segments.indices.contains(segmentIndex), segments[segmentIndex].range.upperBound <= frames.count else { return frames }
        var f = Array(frames[segments[segmentIndex].range])
        for i in f.indices { f[i].id = i }
        return f
    }

    func selectSegment(_ i: Int) {
        guard i != segmentIndex, segments.indices.contains(i) else { return }
        segmentIndex = i
        startAnalysis()
    }

    func startAnalysis(hint: (frame: Int, point: V2)? = nil, fresh: Bool = false) {
        analysisTask?.cancel(); cancelFlag.cancel()
        stop()
        let flag = CancelFlag(); cancelFlag = flag
        let fr = currentFrames
        guard !fr.isEmpty else { return }
        let fps = segments.indices.contains(segmentIndex) ? segments[segmentIndex].fps : FrameImporter.estimateFPS(fr)
        phase = .analyzing(stage: "准备", progress: 0)
        analysisStarted = Date()
        let existingModels = models
        // "重新识别" of the same photos keeps the user's corrections; picking another bird starts clean
        let fpNow = Analyzer.fingerprint(fr)
        let keep: (eyes: [Int: V2], excluded: Set<Int>)? = (hint == nil && analysis?.fingerprint == fpNow)
            ? (analysis!.manualEye, analysis!.excluded) : nil
        analysisTask = Task.detached(priority: .userInitiated) { [weak self] in
            let fp = fpNow
            if hint == nil, !fresh, var cached = ProxyCache.shared.loadAnalysis(fingerprint: fp) {
                cached.track = TrackBuilder.build(cached)
                await self?.finishAnalysis(cached, flag: flag)
                return
            }
            do {
                let m: BirdModels
                if let existingModels { m = existingModels } else {
                    await MainActor.run { self?.phase = .analyzing(stage: "加载识别模型", progress: 0) }
                    m = try BirdModels()
                    await MainActor.run { self?.models = m }
                }
                let az = Analyzer(models: m)
                var a = try az.analyze(frames: fr, fps: fps, targetHint: hint, progress: { stage, p in
                    Task { @MainActor in
                        guard !flag.isCancelled else { return }
                        if case .analyzing = self?.phase { self?.phase = .analyzing(stage: stage.rawValue, progress: p) }
                    }
                }, isCancelled: { flag.isCancelled })
                a.manualEye = keep?.eyes ?? [:]
                a.excluded = keep?.excluded ?? []
                if !a.manualEye.isEmpty { a.track = TrackBuilder.build(a) }
                ProxyCache.shared.saveAnalysis(a)
                await self?.finishAnalysis(a, flag: flag)
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    guard !flag.isCancelled else { return }
                    self?.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func finishAnalysis(_ a: SequenceAnalysis, flag: CancelFlag) {
        // a newer import / analysis replaced this one
        guard flag === cancelFlag, !flag.isCancelled else { return }
        sourceDetail = nil
        currentFrame = clamp(currentFrame, 0, max(0, a.count - 1))
        analysis = a
        phase = .ready
        selection.trimEnd = nil
        selection.trimStart = 0
        rebuildJob(immediate: true)
    }

    func cancelAnalysis() {
        cancelFlag.cancel()
        analysisTask?.cancel()
        if analysis == nil {
            frames = []; segments = []; segmentIndex = 0
            phase = .empty
        } else {
            phase = .ready
        }
    }

    // MARK: - Settings -> RenderJob

    private func settingsChanged() {
        scheduleSettingsSave()
        rebuildJob(immediate: false)
    }

    func applyPreset(_ p: CompositionPreset) {
        presetID = p.id
        // keep the edge handling the user chose
        var c = p.composition
        c.edgeFill = composition.edgeFill
        c.edgeMargin = composition.edgeMargin
        c.maxEdgeZoom = composition.maxEdgeZoom
        composition = c
    }

    func isPresetActive(_ p: CompositionPreset) -> Bool {
        var c = p.composition
        c.edgeFill = composition.edgeFill; c.edgeMargin = composition.edgeMargin; c.maxEdgeZoom = composition.maxEdgeZoom
        return presetID == p.id && c == composition
    }

    func rebuildJob(immediate: Bool) {
        rebuildWork?.cancel()
        guard let a = analysis else { return }
        let comp = composition, look = look, ex = exportSettings, sel = selection
        let work = DispatchWorkItem { [weak self] in
            let job = RenderJob(analysis: a, composition: comp, look: look, export: ex, selection: sel)
            DispatchQueue.main.async {
                guard let self, self.analysis?.fingerprint == a.fingerprint else { return }
                let durationChanged = abs((self.job?.duration ?? -1) - job.duration) > 1e-6
                self.job = job
                self.playheadOutput = min(self.playheadOutput, max(0, job.outputFrames.count - 1))
                self.refreshPreview()
                if durationChanged { self.rebuildAudioPlayer() }
            }
        }
        rebuildWork = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + (immediate ? 0 : 0.06), execute: work)
    }

    // MARK: - Edits

    func setManualEye(_ p: V2, frame: Int? = nil) {
        guard var a = analysis else { return }
        let i = frame ?? currentFrame
        guard a.frames.indices.contains(i) else { return }
        a.manualEye[i] = p
        a.track = TrackBuilder.build(a)
        analysis = a
        scheduleSave()
        rebuildJob(immediate: true)
    }

    func clearManualEye(all: Bool = false) {
        guard var a = analysis else { return }
        if all { a.manualEye.removeAll() } else { a.manualEye[currentFrame] = nil }
        a.track = TrackBuilder.build(a)
        analysis = a
        scheduleSave()
        rebuildJob(immediate: true)
    }

    func toggleExcluded() {
        guard var a = analysis, a.frames.indices.contains(currentFrame) else { return }
        if a.excluded.contains(currentFrame) { a.excluded.remove(currentFrame) } else { a.excluded.insert(currentFrame) }
        analysis = a
        scheduleSave()
        rebuildJob(immediate: true)
    }

    func restoreAllExcluded() {
        guard var a = analysis else { return }
        a.excluded.removeAll()
        analysis = a
        scheduleSave()
        rebuildJob(immediate: true)
    }

    func pickBird(at p: V2) {
        sourceTool = .none
        startAnalysis(hint: (currentFrame, p))
    }

    private func scheduleSave() {
        saveWork?.cancel()
        guard let a = analysis else { return }
        let w = DispatchWorkItem { ProxyCache.shared.saveAnalysis(a) }
        saveWork = w
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: w)
    }

    /// Frame whose eye position is inferred from the rest of the head (eye hidden), not yet corrected by hand.
    func isPredicted(_ i: Int) -> Bool {
        guard let a = analysis, let t = a.track, t.frames.indices.contains(i) else { return false }
        return !t.frames[i].eyeVisible && t.frames[i].hasData && a.manualEye[i] == nil
    }

    /// Predicted frames that end up in the video
    var predictedFrames: [Int] {
        guard let a = analysis else { return [] }
        return (0..<a.count).filter { i in
            isPredicted(i) && (job.map { $0.status.indices.contains(i) && $0.status[i] == .ok } ?? true)
        }
    }

    func jumpToPredicted(_ direction: Int) {
        let p = predictedFrames
        guard !p.isEmpty else { return }
        stop()
        let target = direction > 0 ? (p.first { $0 > currentFrame } ?? p.first!) : (p.last { $0 < currentFrame } ?? p.last!)
        seek(target)
    }

    /// Switch to the source view with the eye tool active, zoomed in on the head.
    func startFixingEye() {
        stop()
        viewMode = .source
        sourceTool = .fixEye
        if sourceZoom < 2 { sourceZoom = 4 }
        refreshPreview()
    }

    // MARK: - Interactive framing (drag the crop in the source view)

    private struct CropEdit {
        var start: Composition
        /// framing the crop actually shows in this frame (smaller than the setting when limited by the photo)
        var startFraming: Double
        var xform: FrameXform
        var mirrored: Bool
        var outW: Double
        var outH: Double
    }
    private var cropEdit: CropEdit?

    func beginCropEdit() {
        guard let job, job.contains(currentFrame) else { return }
        stop()
        let xf = job.plan.xforms[currentFrame]
        let outW = Double(job.outputSize.w), outH = Double(job.outputSize.h)
        var startFraming = composition.framing
        if let t = analysis?.track, t.frames.indices.contains(currentFrame), xf.z > 0 {
            let shown = min(outW, outH) / xf.z / t.frames[currentFrame].headLength
            if shown.isFinite, shown < startFraming * 0.98 { startFraming = shown }
        }
        cropEdit = CropEdit(start: composition, startFraming: startFraming, xform: xf, mirrored: job.plan.mirrored,
                            outW: outW, outH: outH)
    }

    /// Move the crop by `d` source pixels: the bird keeps its place in the photo, so its position in the frame changes.
    func moveCrop(by d: V2) {
        guard let e = cropEdit else { return }
        let dOut = -e.xform.z * d.rotated(e.xform.psi)
        var c = composition
        c.anchorX = clamp(e.start.anchorX + (e.mirrored ? -1 : 1) * dOut.x / e.outW, 0.05, 0.95)
        c.anchorY = clamp(e.start.anchorY + dOut.y / e.outH, 0.05, 0.95)
        composition = c
    }

    /// Scale the crop by `r` (>1 = wider)
    func scaleCrop(by r: Double) {
        guard let e = cropEdit, r.isFinite, r > 0 else { return }
        let range = Composition.framingRange
        composition.framing = clamp(e.startFraming * r, range.lowerBound, range.upperBound)
    }

    func endCropEdit() { cropEdit = nil }

    // MARK: - Preview & playback

    var outputFrameCount: Int { job?.outputFrames.count ?? 0 }

    func refreshPreview() {
        guard let job else { return }
        if viewMode == .source {
            engine.requestSource(job: job, index: currentFrame) { [weak self] img in self?.sourceImage = img }
            if sourceDetail?.frame != currentFrame { sourceDetail = nil }
        } else {
            let of: OutputFrame
            if isPlaying, playheadOutput < job.outputFrames.count {
                of = job.outputFrames[playheadOutput]
            } else {
                of = OutputFrame(a: currentFrame, b: currentFrame, t: 0, fade: 1)
            }
            engine.requestOutput(job: job, frame: of, maxSide: 1400) { [weak self] img in self?.previewImage = img }
            // When paused, follow up with a sharper render from the original file
            hiResWork?.cancel()
            if !isPlaying {
                let w = DispatchWorkItem { [weak self] in
                    guard let self, !self.isPlaying, self.viewMode == .output, let job = self.job else { return }
                    let frame = self.currentFrame
                    self.engine.requestOutput(job: job, frame: of, maxSide: 1800, fullResolution: true) { [weak self] img in
                        guard let self, !self.isPlaying, self.currentFrame == frame, self.job === job, let img else { return }
                        self.previewImage = img
                    }
                }
                hiResWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
            }
        }
    }
    private var hiResWork: DispatchWorkItem?

    /// Request a sharp crop of the original for the zoomed source view.
    func requestSourceDetail(region: CGRect, pixelsAcross: Double) {
        guard viewMode == .source, sourceZoom > 1.01, let job, job.contains(currentFrame) else { return }
        let frame = currentFrame
        engine.requestSourceDetail(job: job, index: frame, region: region, pixelsAcross: pixelsAcross) { [weak self] img, rect in
            guard let self, self.currentFrame == frame, let img else { return }
            self.sourceDetail = SourceDetail(image: img, rect: rect, frame: frame)
        }
    }

    func seek(_ i: Int) {
        guard let a = analysis, a.count > 0 else { return }
        currentFrame = clamp(i, 0, a.count - 1)
        if isPlaying, let job, let k = job.outputFrames.firstIndex(where: { $0.a >= currentFrame }) { playheadOutput = k }
        refreshPreview()
    }

    func step(_ d: Int) {
        stop()
        guard let job else { seek(currentFrame + d); return }
        // step through used frames only when in output mode
        if viewMode == .output, !job.used.isEmpty {
            if d > 0, let nxt = job.used.first(where: { $0 > currentFrame }) { seek(nxt); return }
            if d < 0, let prv = job.used.last(where: { $0 < currentFrame }) { seek(prv); return }
        }
        seek(currentFrame + d)
    }

    func togglePlay() { isPlaying ? stop() : play() }

    func play() {
        guard let job, !job.outputFrames.isEmpty else { return }
        if viewMode == .source { viewMode = .output }
        isPlaying = true
        if let k = job.outputFrames.firstIndex(where: { $0.a >= currentFrame }), k < job.outputFrames.count - 1 { playheadOutput = k } else { playheadOutput = 0 }
        playTimer?.invalidate()
        let fps = job.export.outputFPS
        let interval = 1 / fps
        var start = Date()
        var startIdx = playheadOutput
        startAudio(at: Double(startIdx) / fps)
        playTimer = Timer.scheduledTimer(withTimeInterval: interval / 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let job = self.job, self.isPlaying else { return }
                let n = job.outputFrames.count
                guard n > 0 else { return }
                var k = startIdx + Int(Date().timeIntervalSince(start) * fps)
                if k >= n {
                    guard self.loopPlayback else { self.stop(); return }
                    // restart the loop (and the music) from the beginning
                    start = Date(); startIdx = 0; k = 0
                    self.startAudio(at: 0)
                }
                if k != self.playheadOutput || self.previewImage == nil {
                    self.playheadOutput = k
                    self.currentFrame = job.outputFrames[k].a
                    self.engine.prefetch(job: job, frames: (1...6).map { job.outputFrames[(k + $0) % n].a })
                    self.refreshPreview()
                }
            }
        }
    }

    func stop() {
        isPlaying = false
        playTimer?.invalidate(); playTimer = nil
        audioPlayer?.pause()
    }

    // MARK: - Music

    func chooseAudio() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff, .movie]
        p.allowsMultipleSelection = false
        p.message = "选择背景音乐（MP3 / M4A / WAV / AIFF，也可以选视频里的音轨）"
        if p.runModal() == .OK, let u = p.url { setAudio(u) }
    }

    func setAudio(_ url: URL) {
        var a = audio
        a.url = url
        a.startOffset = 0
        audio = a
    }

    func removeAudio() { audio.url = nil }

    private func audioChanged(from old: AudioSettings) {
        guard old != audio else { return }
        if let d = try? JSONEncoder().encode(audio) { UserDefaults.standard.set(d, forKey: "audio.v1") }
        if old.url != audio.url { loadAudioOverview() }
        rebuildAudioPlayer()
    }

    private func loadAudioOverview() {
        audioOverviewTask?.cancel()
        audioOverview = nil
        audioMessage = nil
        guard let url = audio.url else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            audioMessage = "找不到音乐文件：\(url.lastPathComponent)"
            return
        }
        audioOverviewTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try AudioMixer.overview(url: url) }
            await MainActor.run {
                guard let self, self.audio.url == url else { return }
                switch result {
                case .success(let o):
                    self.audioOverview = o
                    if self.audio.startOffset > o.duration { self.audio.startOffset = 0 }
                case .failure(let e): self.audioMessage = e.localizedDescription
                }
            }
        }
    }

    /// Rebuilds the preview player (same mix as the export) after music or duration changes.
    func rebuildAudioPlayer() {
        audioBuildTask?.cancel()
        guard audio.isActive, let job, job.duration > 0 else {
            audioPlayer?.pause(); audioPlayer = nil
            return
        }
        let s = audio, duration = job.duration
        audioBuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)   // debounce slider drags
            guard !Task.isCancelled, let (comp, mix) = try? await AudioMixer.makeMix(s, duration: duration), !Task.isCancelled,
                  let self else { return }
            let item = AVPlayerItem(asset: comp)
            item.audioMix = mix
            if let p = self.audioPlayer { p.replaceCurrentItem(with: item) } else { self.audioPlayer = AVPlayer(playerItem: item) }
            if self.isPlaying, let job = self.job { self.startAudio(at: Double(self.playheadOutput) / job.export.outputFPS) }
        }
    }

    private func startAudio(at t: Double) {
        guard previewAudio, audio.isActive, let p = audioPlayer else { return }
        p.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        p.play()
    }

    func togglePreviewAudio() {
        previewAudio.toggle()
        if !previewAudio { audioPlayer?.pause() }
        else if isPlaying, let job { startAudio(at: Double(playheadOutput) / job.export.outputFPS) }
    }

    // MARK: - Watermark

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let d = base.appendingPathComponent("BirdLock", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func chooseWatermark() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.png, .tiff, .heic, .jpeg]
        p.allowsMultipleSelection = false
        p.message = "选择水印图片（推荐带透明背景的 PNG，例如签名）"
        guard p.runModal() == .OK, let u = p.url else { return }
        // keep a private copy so the watermark survives moving / deleting the original
        let dest = Self.supportDirectory.appendingPathComponent("watermark-\(UUID().uuidString.prefix(8)).\(u.pathExtension.lowercased())")
        do {
            try FileManager.default.copyItem(at: u, to: dest)
        } catch {
            exportState.message = "无法读取水印图片：\(error.localizedDescription)"
            return
        }
        let old = watermark.imagePath
        var w = watermark
        w.imagePath = dest.path
        w.enabled = true
        watermark = w
        if let old, old.hasPrefix(Self.supportDirectory.path) { try? FileManager.default.removeItem(atPath: old) }
    }

    private func watermarkChanged(from old: WatermarkSettings) {
        guard old != watermark else { return }
        if let d = try? JSONEncoder().encode(watermark) { UserDefaults.standard.set(d, forKey: "watermark.v1") }
        if old.imagePath != watermark.imagePath { loadWatermarkImage() }
    }

    private func loadWatermarkImage() {
        watermarkImage = watermark.imagePath.flatMap { ImageLoader.load(URL(fileURLWithPath: $0)) }
    }

    // MARK: - Export

    enum ExportKind: String, CaseIterable, Identifiable {
        case video, images, gif
        var id: String { rawValue }
        var title: String { ["video": "视频", "images": "对齐后的图片序列", "gif": "GIF 动图"][rawValue]! }
    }

    func export(kind: ExportKind, to url: URL) {
        guard let a = analysis else { return }
        stop()
        // a fresh job with the latest settings plus the watermark (the preview job draws it separately)
        let job = RenderJob(analysis: a, composition: composition, look: look, export: exportSettings,
                            selection: selection, watermark: watermark)
        let music: AudioSettings? = kind == .video && audio.isActive ? audio : nil
        exportState = ExportState(running: true, progress: 0, message: "正在导出…", outputURL: url)
        let flag = CancelFlag(); exportCancel = flag
        Task.detached(priority: .userInitiated) { [weak self] in
            let ex = VideoExporter()
            let t0 = Date()
            do {
                let prog: (Double) -> Void = { p in Task { @MainActor in self?.exportState.progress = p } }
                switch kind {
                case .video: try ex.export(job: job, to: url, audio: music, progress: prog, isCancelled: { flag.isCancelled })
                case .images: try ex.exportImages(job: job, to: url, type: .jpeg, progress: prog, isCancelled: { flag.isCancelled })
                case .gif: try ex.exportGIF(job: job, to: url, progress: prog, isCancelled: { flag.isCancelled })
                }
                let dt = Date().timeIntervalSince(t0)
                await MainActor.run {
                    self?.exportState.running = false
                    self?.exportState.progress = 1
                    self?.exportState.message = String(format: "导出完成（%.0f 秒）", dt)
                }
            } catch {
                await MainActor.run {
                    self?.exportState.running = false
                    self?.exportState.message = error.localizedDescription
                }
            }
        }
    }

    private var exportCancel = CancelFlag()
    func cancelExport() { exportCancel.cancel() }

    // MARK: - Persistence

    private struct Saved: Codable {
        var version: Int?
        var composition: Composition
        var look: LookSettings
        var export: ExportSettings
        var selection: FrameSelection
        var presetID: String?
    }
    private static let settingsVersion = 2

    private var loading = false
    private func scheduleSettingsSave() {
        guard !loading else { return }
        settingsSaveWork?.cancel()
        let s = Saved(version: Self.settingsVersion, composition: composition, look: look, export: exportSettings,
                      selection: selection, presetID: presetID)
        let w = DispatchWorkItem {
            if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: "settings.v1") }
        }
        settingsSaveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    private func loadSettings() {
        loading = true
        defer { loading = false }
        let ud = UserDefaults.standard
        if let d = ud.data(forKey: "settings.v1"), let s = try? JSONDecoder().decode(Saved.self, from: d) {
            var comp = s.composition
            // v2: the new "shift" edge handling replaces auto-zoom as the default
            if (s.version ?? 1) < 2 && comp.edgeFill == .autoZoom { comp.edgeFill = .shift }
            composition = comp; look = s.look; exportSettings = s.export
            var sel = s.selection; sel.trimStart = 0; sel.trimEnd = nil
            selection = sel; presetID = s.presetID
        } else if let p = CompositionPreset.all.first(where: { $0.id == "lead" }) {
            composition = p.composition
        }
        if let d = ud.data(forKey: "watermark.v1"), let w = try? JSONDecoder().decode(WatermarkSettings.self, from: d) {
            watermark = w
            if let path = w.imagePath, !FileManager.default.fileExists(atPath: path) { watermark.imagePath = nil; watermark.enabled = false }
        }
        if let d = ud.data(forKey: "audio.v1"), let a = try? JSONDecoder().decode(AudioSettings.self, from: d) {
            audio = a
            if let u = a.url, !FileManager.default.fileExists(atPath: u.path) { audio.url = nil }
        }
        loading = false
        scheduleSettingsSave()
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func cancel() { lock.lock(); v = true; lock.unlock() }
}
