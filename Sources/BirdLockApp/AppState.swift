import SwiftUI
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

@MainActor
@Observable
final class AppState {
    // Input
    var frames: [SourceFrame] = []
    var segments: [BurstSegment] = []
    var segmentIndex = 0
    var phase: Phase = .empty
    var analysis: SequenceAnalysis?

    // Settings (persisted)
    var composition = Composition() { didSet { settingsChanged() } }
    var look = LookSettings() { didSet { settingsChanged() } }
    var exportSettings = ExportSettings() { didSet { settingsChanged() } }
    var selection = FrameSelection() { didSet { settingsChanged() } }
    var presetID: String? = "lead"

    // Preview
    var job: RenderJob?
    var viewMode: ViewMode = .output
    var sourceTool: SourceTool = .none
    var currentFrame = 0          // source frame index
    var playheadOutput = 0        // index into job.outputFrames while playing
    var isPlaying = false
    var previewImage: CGImage?
    var sourceImage: CGImage?
    var exportState = ExportState()
    var showExportSheet = false
    var loopPlayback = true

    let engine = PreviewEngine()
    private var models: BirdModels?
    private var analysisTask: Task<Void, Never>?
    private var cancelFlag = CancelFlag()
    private var rebuildWork: DispatchWorkItem?
    private var playTimer: Timer?
    private var saveWork: DispatchWorkItem?

    init() {
        loadSettings()
    }

    // MARK: - Import & analysis

    func importURLs(_ urls: [URL]) {
        stop()
        analysisTask?.cancel(); cancelFlag.cancel()
        phase = .importing
        analysis = nil; job = nil; previewImage = nil; sourceImage = nil
        Task.detached(priority: .userInitiated) {
            let all = FrameImporter.importFrames(urls)
            let segs = FrameImporter.segments(all)
            await MainActor.run {
                self.frames = all
                self.segments = segs
                guard !all.isEmpty else { self.phase = .failed("没有找到 JPG / HEIF 图片"); return }
                // choose the longest burst by default
                self.segmentIndex = segs.indices.max { segs[$0].range.count < segs[$1].range.count } ?? 0
                self.startAnalysis()
            }
        }
    }

    var currentFrames: [SourceFrame] {
        guard segmentIndex < segments.count else { return frames }
        var f = Array(frames[segments[segmentIndex].range])
        for i in f.indices { f[i].id = i }
        return f
    }

    func selectSegment(_ i: Int) {
        guard i != segmentIndex, i < segments.count else { return }
        segmentIndex = i
        startAnalysis()
    }

    func startAnalysis(hint: (frame: Int, point: V2)? = nil, fresh: Bool = false) {
        analysisTask?.cancel(); cancelFlag.cancel()
        let flag = CancelFlag(); cancelFlag = flag
        let fr = currentFrames
        guard !fr.isEmpty else { return }
        let fps = segments.indices.contains(segmentIndex) ? segments[segmentIndex].fps : FrameImporter.estimateFPS(fr)
        phase = .analyzing(stage: "准备", progress: 0)
        let existingModels = models
        analysisTask = Task.detached(priority: .userInitiated) { [weak self] in
            let fp = Analyzer.fingerprint(fr)
            if hint == nil, !fresh, var cached = ProxyCache.shared.loadAnalysis(fingerprint: fp) {
                cached.track = TrackBuilder.build(cached)
                await self?.finishAnalysis(cached)
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
                        if case .analyzing = self?.phase { self?.phase = .analyzing(stage: stage.rawValue, progress: p) }
                    }
                }, isCancelled: { flag.isCancelled })
                // keep manual edits when re-analysing with a hint is not meaningful; start clean
                a.manualEye = [:]
                ProxyCache.shared.saveAnalysis(a)
                await self?.finishAnalysis(a)
            } catch is CancellationError {
            } catch {
                await MainActor.run { self?.phase = .failed(error.localizedDescription) }
            }
        }
    }

    private func finishAnalysis(_ a: SequenceAnalysis) {
        analysis = a
        phase = .ready
        currentFrame = min(currentFrame, a.count - 1)
        selection.trimEnd = nil
        selection.trimStart = 0
        rebuildJob(immediate: true)
    }

    func cancelAnalysis() {
        cancelFlag.cancel()
        analysisTask?.cancel()
        phase = analysis == nil ? .empty : .ready
    }

    // MARK: - Settings -> RenderJob

    private func settingsChanged() {
        saveSettings()
        rebuildJob(immediate: false)
    }

    func applyPreset(_ p: CompositionPreset) {
        presetID = p.id
        composition = p.composition
    }

    func rebuildJob(immediate: Bool) {
        rebuildWork?.cancel()
        guard let a = analysis else { return }
        let comp = composition, look = look, ex = exportSettings, sel = selection
        let work = DispatchWorkItem { [weak self] in
            let job = RenderJob(analysis: a, composition: comp, look: look, export: ex, selection: sel)
            DispatchQueue.main.async {
                guard let self else { return }
                self.job = job
                self.playheadOutput = min(self.playheadOutput, max(0, job.outputFrames.count - 1))
                self.refreshPreview()
            }
        }
        rebuildWork = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + (immediate ? 0 : 0.08), execute: work)
    }

    // MARK: - Edits

    func setManualEye(_ p: V2) {
        guard var a = analysis else { return }
        a.manualEye[currentFrame] = p
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
        guard var a = analysis else { return }
        if a.excluded.contains(currentFrame) { a.excluded.remove(currentFrame) } else { a.excluded.insert(currentFrame) }
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

    // MARK: - Preview & playback

    var outputFrameCount: Int { job?.outputFrames.count ?? 0 }

    func refreshPreview() {
        guard let job else { return }
        if viewMode == .source {
            engine.requestSource(job: job, index: currentFrame) { [weak self] img in self?.sourceImage = img }
        } else {
            let of: OutputFrame
            if isPlaying, playheadOutput < job.outputFrames.count {
                of = job.outputFrames[playheadOutput]
            } else {
                of = OutputFrame(a: currentFrame, b: currentFrame, t: 0, fade: 1)
            }
            engine.requestOutput(job: job, frame: of, maxSide: 1400) { [weak self] img in self?.previewImage = img }
            // When paused, follow up with a sharp render from the original file
            hiResWork?.cancel()
            if !isPlaying {
                let w = DispatchWorkItem { [weak self] in
                    guard let self, !self.isPlaying, self.viewMode == .output, let job = self.job else { return }
                    let frame = self.currentFrame
                    self.engine.requestOutput(job: job, frame: of, maxSide: 1600, fullResolution: true) { [weak self] img in
                        guard let self, !self.isPlaying, self.currentFrame == frame, self.job === job, let img else { return }
                        self.previewImage = img
                    }
                }
                hiResWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
            }
        }
    }
    private var hiResWork: DispatchWorkItem?

    func seek(_ i: Int) {
        guard let a = analysis else { return }
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
        let interval = 1 / job.export.outputFPS
        let start = Date()
        let startIdx = playheadOutput
        playTimer = Timer.scheduledTimer(withTimeInterval: interval / 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let job = self.job, self.isPlaying else { return }
                let n = job.outputFrames.count
                guard n > 0 else { return }
                var k = startIdx + Int(Date().timeIntervalSince(start) * job.export.outputFPS)
                if k >= n {
                    if self.loopPlayback { k = k % n } else { self.stop(); return }
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
    }

    // MARK: - Export

    enum ExportKind: String, CaseIterable, Identifiable {
        case video, images, gif
        var id: String { rawValue }
        var title: String { ["video": "视频", "images": "对齐后的图片序列", "gif": "GIF 动图"][rawValue]! }
    }

    func export(kind: ExportKind, to url: URL) {
        guard let job else { return }
        stop()
        exportState = ExportState(running: true, progress: 0, message: "正在导出…", outputURL: url)
        let flag = CancelFlag(); exportCancel = flag
        Task.detached(priority: .userInitiated) { [weak self] in
            let ex = VideoExporter()
            let t0 = Date()
            do {
                let prog: (Double) -> Void = { p in Task { @MainActor in self?.exportState.progress = p } }
                switch kind {
                case .video: try ex.export(job: job, to: url, progress: prog, isCancelled: { flag.isCancelled })
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
        var composition: Composition
        var look: LookSettings
        var export: ExportSettings
        var selection: FrameSelection
        var presetID: String?
    }

    private var loading = false
    private func saveSettings() {
        guard !loading else { return }
        let s = Saved(composition: composition, look: look, export: exportSettings, selection: selection, presetID: presetID)
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: "settings.v1") }
    }

    private func loadSettings() {
        loading = true
        defer { loading = false }
        if let d = UserDefaults.standard.data(forKey: "settings.v1"), let s = try? JSONDecoder().decode(Saved.self, from: d) {
            composition = s.composition; look = s.look; exportSettings = s.export
            var sel = s.selection; sel.trimStart = 0; sel.trimEnd = nil
            selection = sel; presetID = s.presetID
        } else if let p = CompositionPreset.all.first(where: { $0.id == "lead" }) {
            composition = p.composition
        }
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func cancel() { lock.lock(); v = true; lock.unlock() }
}
