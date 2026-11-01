import SwiftUI
import AppKit
import AVFoundation
import Observation
import BirdLockCore
import BirdLockAircraftRuntime
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
    var cancelling = false
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
    let cacheOwner=UUID().uuidString
    var projectURL: URL?
    var projectDirty = false
    var projectCloseApproved = false
    var showReleaseNotes = false
    var releaseNotesPending = false
    let releaseNotice: ReleaseNotice
    var showCacheSheet = false
    var cacheMessage = ""
    var cacheLimitGB = 20 { didSet { defaults.set(cacheLimitGB,forKey:"cache.limitGB") } }
    var askCleanupAfterExport = true { didSet { defaults.set(askCleanupAfterExport,forKey:"cache.askAfterExport") } }
    // Input
    var frames: [SourceFrame] = []
    var segments: [BurstSegment] = []
    var segmentIndex = 0
    var mergeGroupIndices: [Int] = []
    var phase: Phase = .empty
    var analysis: SequenceAnalysis?
    var analysisStarted = Date()
    var timelineMessage: String?
    var videoImportURL: URL?
    var importMessage = "正在读取照片…"
    private var jobGeneration = 0

    // Settings (persisted)
    var composition = Composition() { didSet { settingsChanged() } }
    var look = LookSettings() { didSet { settingsChanged() } }
    var exportSettings = ExportSettings() { didSet { settingsChanged() } }
    var selection = FrameSelection() { didSet { settingsChanged() } }
    var presetID: String? = "lead"
    var subject: AnalysisSubject = .bird
    private var subjectProfiles: [String: SubjectProfile] = [:]
    private struct SubjectRollback {
        var subject: AnalysisSubject
        var analysis: SequenceAnalysis
        var frame: Int
        var view: ViewMode
        var zoom: Double
        var frames: [SourceFrame]
        var segments: [BurstSegment]
        var segmentIndex: Int
        var mergeGroups: [Int]
    }
    private var subjectRollback: SubjectRollback?
    var isAircraft: Bool { subject == .aircraft }
    var presets: [CompositionPreset] { CompositionPreset.forSubject(subject) }
    var audio = AudioSettings() { didSet { audioChanged(from: oldValue) } }
    var watermark = WatermarkSettings() { didSet { watermarkChanged(from: oldValue) } }

    // Music & watermark
    var musicCues: [MusicCue] = []
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

    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.releaseNotice=ReleaseNotice(defaults:defaults,current:AppDocs.appVersion)
        loadSettings()
        cacheLimitGB=defaults.object(forKey:"cache.limitGB") == nil ? 20 : max(0,min(4096,defaults.integer(forKey:"cache.limitGB")))
        askCleanupAfterExport=defaults.object(forKey:"cache.askAfterExport") == nil ? true : defaults.bool(forKey:"cache.askAfterExport")
    }

    // MARK: - Import & analysis

    func importURLs(_ urls: [URL], merge: Bool = false) {
        if urls.contains(where: { VideoImporter.extensions.contains($0.pathExtension.lowercased()) }) {
            guard urls.count == 1 else { timelineMessage = "视频请每次单独导入一个文件"; return }
            videoImportURL = urls[0]; return
        }
        subjectRollback = nil
        stop()
        analysisTask?.cancel(); cancelFlag.cancel()
        importGeneration += 1
        let generation = importGeneration
        phase = .importing
        importMessage = "正在读取照片…"
        analysis = nil; job = nil; previewImage = nil; sourceImage = nil; sourceDetail = nil
        Task.detached(priority: .userInitiated) {
            let cacheOperation=CachePolicy.beginOperation(root:ProxyCache.shared.root)
            defer { CachePolicy.endOperation(cacheOperation);Task { @MainActor [weak self] in self?.trimCache() } }
            let all = FrameImporter.importFrames(urls)
            let segs = FrameImporter.segments(all)
            await MainActor.run {
                // a newer import started meanwhile
                guard generation == self.importGeneration else { return }
                self.segmentIndex = 0
                self.projectURL=nil;self.projectDirty=true
                self.frames = all
                ProxyCache.shared.retainRecords(frames:all)
                self.segments = segs
                CachePolicy.protect(owner:self.cacheOwner,roots:self.protectedCache)
                let saved = self.defaults.array(forKey: "groupOrder." + Analyzer.fingerprint(all)) as? [Int] ?? []
                self.mergeGroupIndices = !saved.isEmpty && Set(saved).count == saved.count && saved.allSatisfy(segs.indices.contains) ? saved : Array(segs.indices)
                self.currentFrame = 0
                guard !all.isEmpty else { self.phase = .failed("没有找到 JPG / HEIF 图片"); return }
                self.audio.tracks.removeAll { $0.videoOriginal }
                // choose the longest burst by default
                self.segmentIndex = merge && segs.count > 1 ? -1 : (segs.indices.max { segs[$0].range.count < segs[$1].range.count } ?? 0)
                self.startAnalysis()
            }
        }
    }

    func importVideo(_ url: URL, options: VideoImportOptions) {
        stop(); analysisTask?.cancel(); cancelFlag.cancel()
        subjectRollback = nil
        importGeneration += 1
        let generation = importGeneration, flag = CancelFlag()
        cancelFlag = flag
        phase = .importing; importMessage = "正在读取视频帧… 0%"
        analysisTask = Task.detached(priority: .userInitiated) { [weak self] in
            let cacheOperation=CachePolicy.beginOperation(root:ProxyCache.shared.root)
            defer { CachePolicy.endOperation(cacheOperation);Task { @MainActor [weak self] in self?.trimCache() } }
            do {
                let result = try VideoImporter.extract(url, options: options, progress: { p in
                    Task { @MainActor in
                        guard let self, self.importGeneration == generation, !flag.isCancelled else { return }
                        self.importMessage = "正在读取视频帧… \(Int(p*100))%"
                    }
                }, isCancelled: { flag.isCancelled })
                _ = try VideoStabilization.prepare(frames: result.frames, video: url, start: options.start,
                    fps: result.fps, profile: options.profile, isCancelled: { flag.isCancelled }, progress: { p in
                        Task { @MainActor in
                            guard let self, self.importGeneration == generation, !flag.isCancelled else { return }
                            self.importMessage = "正在分析画面防抖… \(Int(p*100))%"
                        }
                    })
                let original = try VideoSource.originalTrack(frames: result.frames)
                await MainActor.run {
                    guard let self, generation == self.importGeneration, !flag.isCancelled else { return }
                    if let a = self.analysis { ProxyCache.shared.saveAnalysis(a) }
                    self.projectURL=nil;self.projectDirty=true
                    self.frames = result.frames
                    ProxyCache.shared.retainRecords(frames:result.frames)
                    self.segments = [BurstSegment(range: 0..<result.frames.count, fps: result.fps)]
                    self.segmentIndex = 0; self.mergeGroupIndices = [0]; self.currentFrame = 0
                    self.analysis = nil; self.job = nil; self.previewImage = nil; self.sourceImage = nil; self.sourceDetail = nil
                    self.selection.dropUntracked = false
                    self.audio.tracks.removeAll { $0.videoOriginal }
                    if let original { self.audio.tracks.append(original) }
                    self.timelineMessage = "视频已导入，可在「画面」调节防抖。" + (original == nil ? "" : "已导入视频原声。")
                    CachePolicy.protect(owner:self.cacheOwner,roots:self.protectedCache)
                    self.startAnalysis()
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    guard let self, generation == self.importGeneration, !flag.isCancelled else { return }
                    if self.analysis != nil { self.phase = .ready; self.timelineMessage = error.localizedDescription }
                    else { self.phase = .failed(error.localizedDescription) }
                }
            }
        }
    }

    var isVideoProject: Bool {
        guard let first = currentFrames.first else { return false }
        return FileManager.default.fileExists(atPath: first.url.deletingLastPathComponent().appendingPathComponent("video-source.json").path)
    }

    func importVideoGyro() {
        guard analysis != nil, isVideoProject else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        panel.message = "选择陀螺仪记录、Gyroflow 工程或含陀螺仪的相机原片"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        CachePolicy.protect(owner:cacheOwner,roots:protectedCache)
        let fr = currentFrames, generation = importGeneration, flag = cancelFlag
        timelineMessage = "正在读取陀螺仪记录…"
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let sync = try VideoStabilization.importGyro(frames: fr, source: source, isCancelled: { flag.isCancelled })
                await MainActor.run {
                    guard let self, self.importGeneration == generation, !flag.isCancelled else { return }
                    self.look.stabilization.autoSync = true
                    self.timelineMessage = sync.valid
                        ? String(format: "已同步：%+.1f ms，可信度 %.0f%%", sync.offset * 1000, sync.score * 100)
                        : "已导入陀螺仪记录；自动同步未通过，请在「画面」调整时间偏移。"
                    self.rebuildJob(immediate: true)
                }
            } catch {
                await MainActor.run {
                    guard let self, self.importGeneration == generation, !flag.isCancelled else { return }
                    self.timelineMessage = error.localizedDescription
                }
            }
        }
    }

    var currentFrames: [SourceFrame] {
        if segmentIndex == -1 {
            var result = mergeGroupIndices.filter { segments.indices.contains($0) }.flatMap { Array(frames[segments[$0].range]) }
            for i in result.indices { result[i].id = i }
            return result
        }
        guard segments.indices.contains(segmentIndex), segments[segmentIndex].range.upperBound <= frames.count else { return frames }
        var f = Array(frames[segments[segmentIndex].range])
        for i in f.indices { f[i].id = i }
        return f
    }

    func selectSegment(_ i: Int) {
        guard i != segmentIndex, segments.indices.contains(i) || (i == -1 && segments.count > 1) else { return }
        if let a = analysis { ProxyCache.shared.saveAnalysis(a) }
        segmentIndex = i
        startAnalysis()
    }

    var timelineClips: [BurstClip] {
        guard segmentIndex == -1 else { return [] }
        var start = 0
        return mergeGroupIndices.filter { segments.indices.contains($0) }.map { i in
            let s = segments[i]
            defer { start += s.range.count }
            return BurstClip(start: start, count: s.range.count, fps: FrameImporter.estimateFPS(Array(frames[s.range])))
        }
    }

    func rememberGroupOrder() {
        guard !frames.isEmpty else { return }
        if !loading,analysis != nil { projectDirty=true;projectCloseApproved=false }
        defaults.set(mergeGroupIndices, forKey: "groupOrder." + Analyzer.fingerprint(frames))
    }

    func includeGroup(_ i: Int, enabled: Bool) {
        if enabled, !mergeGroupIndices.contains(i) { mergeGroupIndices.append(i) }
        if !enabled, mergeGroupIndices.count > 1 { mergeGroupIndices.removeAll { $0 == i } }
        rememberGroupOrder()
        if segmentIndex == -1 { startAnalysis() }
    }

    func startAnalysis(hint: (frame: Int, point: V2)? = nil, fresh: Bool = false) {
        analysisTask?.cancel(); cancelFlag.cancel()
        stop()
        let flag = CancelFlag(); cancelFlag = flag
        CachePolicy.protect(owner:cacheOwner,roots:protectedCache)
        let fr = currentFrames
        let clips = timelineClips
        guard !fr.isEmpty else { return }
        let fps = segments.indices.contains(segmentIndex) ? segments[segmentIndex].fps : FrameImporter.estimateFPS(fr)
        phase = .analyzing(stage: "准备", progress: 0)
        analysisStarted = Date()
        let existingModels = models
        let kind = subject
        let partsDirectory: URL?
        let fpNow: String
        do {
            if kind == .aircraft {
                let directory = try AircraftModelResources.directory()
                let manifest = try AircraftModelManifest.load(directory: directory,verifyWeights: false)
                partsDirectory = directory
                fpNow = Analyzer.fingerprint(fr,aircraftModelIdentity: manifest.analysisIdentity)
            } else { partsDirectory = nil;fpNow = Analyzer.fingerprint(fr) }
        } catch { phase = .failed(error.localizedDescription);return }
        let keptShots = analysis?.fingerprint == fpNow ? analysis?.closeups : nil
        // "重新识别" of the same photos keeps the user's corrections; picking another bird starts clean
        let keep: (eyes: [Int: V2], excluded: Set<Int>)? = (hint == nil && analysis?.fingerprint == fpNow)
            ? (analysis!.manualEye, analysis!.excluded) : nil
        analysisTask = Task.detached(priority: .userInitiated) { [weak self] in
            let cacheOperation=CachePolicy.beginOperation(root:ProxyCache.shared.root)
            defer { CachePolicy.endOperation(cacheOperation);Task { @MainActor [weak self] in self?.trimCache() } }
            Diagnostics.record("analysis start subject=\(kind.rawValue) photos=\(fr.count) fps=\(fps)")
            let started = Date()
            let fp = fpNow
            var edits = keep
            var shots = keptShots
            if hint == nil, !fresh, var cached = ProxyCache.shared.loadAnalysis(fingerprint: fp) {
                if clips.count <= 1 || (cached.groupedDetection == true && (cached.clips ?? []) == clips) {
                    cached.clips = clips
                    cached.track = TrackBuilder.build(cached)
                    await self?.finishAnalysis(cached, flag: flag)
                    return
                }
                if edits == nil { edits = (cached.manualEye, cached.excluded) }
                if shots == nil { shots = cached.closeups }
            }
            do {
                let progress: AnalysisProgress = { stage, p in
                    Task { @MainActor in
                        guard !flag.isCancelled else { return }
                        if case .analyzing(let old, _) = self?.phase, old != stage.rawValue {
                            Diagnostics.record("analysis stage=\(stage.rawValue)")
                        }
                        if case .analyzing = self?.phase { self?.phase = .analyzing(stage: stage.rawValue, progress: p) }
                    }
                }
                var a: SequenceAnalysis
                if kind == .aircraft, let partsDirectory {
                    let az = try AircraftAnalyzer(detectorFactory: {
                        guard let url = ModelStore.locate(ModelStore.detectorName) else { throw ModelError.notFound(ModelStore.detectorName) }
                        return try YOLOModel(url: url,keypointCount: 0)
                    },partsDirectory: partsDirectory)
                    a = try az.analyze(frames: fr,fps: fps,targetHint: hint,clips: clips,progress: progress,isCancelled: { flag.isCancelled })
                } else {
                    let m: BirdModels
                    if let existingModels { m = existingModels } else {
                        await MainActor.run { if !flag.isCancelled { self?.phase = .analyzing(stage: "加载识别模型", progress: 0) } }
                        m = try BirdModels()
                        await MainActor.run { if !flag.isCancelled { self?.models = m } }
                    }
                    a = try Analyzer(models: m).analyze(frames: fr,fps: fps,targetHint: hint,progress: progress,isCancelled: { flag.isCancelled },clips: clips)
                }
                a.manualEye = edits?.eyes ?? [:]
                a.excluded = edits?.excluded ?? []
                a.clips = clips
                a.closeups = shots
                if !a.manualEye.isEmpty || !clips.isEmpty { a.track = TrackBuilder.build(a) }
                ProxyCache.shared.saveAnalysis(a)
                Diagnostics.record("analysis complete seconds=\(Date().timeIntervalSince(started)) photos=\(a.count)")
                await self?.finishAnalysis(a, flag: flag)
            } catch is CancellationError {
                Diagnostics.record("analysis cancelled")
            } catch {
                Diagnostics.record("analysis failed: \(error)")
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
        projectDirty=true;projectCloseApproved=false
        subjectRollback = nil
        phase = .ready
        selection.trimEnd = nil
        selection.trimStart = 0
        rebuildJob(immediate: true)
        trimCache()
    }

    func cancelAnalysis() {
        importGeneration += 1
        cancelFlag.cancel()
        analysisTask?.cancel()
        if subjectRollback != nil { restoreSubjectTransition();return }
        if analysis == nil {
            frames = []; segments = []; segmentIndex = 0
            phase = .empty
        } else {
            phase = .ready
        }
    }

    // MARK: - Settings -> RenderJob

    private var currentProfile: SubjectProfile {
        SubjectProfile(composition: composition,look: look,export: exportSettings,selection: selection,presetID: presetID)
    }

    private func applyProfile(_ p: SubjectProfile, resetTrim: Bool = true) {
        let wasLoading = loading;loading = true
        defer { loading = wasLoading }
        let p = resetTrim ? p.untrimmed : p
        composition = p.composition;look = p.look;exportSettings = p.export;selection = p.selection;presetID = p.presetID
    }

    func changeSubject(_ next: AnalysisSubject) {
        guard next != subject, !exportState.running else { return }
        stop();analysisTask?.cancel();cancelFlag.cancel();jobGeneration += 1
        rebuildWork?.cancel();saveWork?.cancel()
        subjectProfiles[subject.rawValue] = currentProfile
        if let a = analysis {
            ProxyCache.shared.saveAnalysis(a)
            subjectRollback = SubjectRollback(subject: subject,analysis: a,frame: currentFrame,view: viewMode,zoom: sourceZoom,
                                               frames: frames,segments: segments,segmentIndex: segmentIndex,mergeGroups: mergeGroupIndices)
        }
        if subjectRollback?.subject == next { restoreSubjectTransition();return }
        subject = next
        if subjectProfiles[next.rawValue] == nil {
            subjectProfiles[next.rawValue] = next == .aircraft ? .initialAircraft(from: subjectProfiles["bird"] ?? currentProfile) : currentProfile
        }
        applyProfile(subjectProfiles[next.rawValue]!)
        models = nil;analysis = nil;job = nil;previewImage = nil;sourceImage = nil;sourceDetail = nil
        sourceTool = .none;currentFrame = 0;scheduleSettingsSave()
        if phase != .importing { if frames.isEmpty { phase = .empty } else { startAnalysis() } }
    }

    private func restoreSubjectTransition() {
        guard let old = subjectRollback else { return }
        subjectProfiles[subject.rawValue] = currentProfile
        subjectRollback = nil;subject = old.subject
        frames = old.frames;segments = old.segments;segmentIndex = old.segmentIndex;mergeGroupIndices = old.mergeGroups
        analysis = old.analysis;currentFrame = old.frame;viewMode = old.view;sourceZoom = old.zoom
        if let profile = subjectProfiles[subject.rawValue] { applyProfile(profile,resetTrim: false) }
        sourceTool = .none;sourceDetail = nil;phase = .ready
        scheduleSettingsSave();rebuildJob(immediate: true)
    }

    private func settingsChanged() {
        guard !loading else { return }
        if analysis != nil { projectDirty=true;projectCloseApproved=false }
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
        jobGeneration += 1
        let generation = jobGeneration
        guard let a = analysis else { return }
        let comp = composition, look = look, ex = exportSettings, sel = selection
        let work = DispatchWorkItem { [weak self] in
            let job = RenderJob(analysis: a, composition: comp, look: look, export: ex, selection: sel)
            DispatchQueue.main.async {
                guard let self, generation == self.jobGeneration, self.analysis?.fingerprint == a.fingerprint else { return }
                let audioChanged = abs((self.job?.duration ?? -1) - job.duration) > 1e-6 || self.job?.mixedAudio(self.audio) != job.mixedAudio(self.audio)
                self.job = job
                self.playheadOutput = min(self.playheadOutput, max(0, job.outputFrames.count - 1))
                self.refreshPreview()
                if audioChanged { self.rebuildAudioPlayer() }
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

    func scheduleSave() {
        if !loading,analysis != nil { projectDirty=true;projectCloseApproved=false }
        saveWork?.cancel()
        guard let a = analysis else { return }
        let w = DispatchWorkItem { ProxyCache.shared.saveAnalysis(a) }
        saveWork = w
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: w)
    }

    /// Frame whose eye position is inferred from the rest of the head (eye hidden), not yet corrected by hand.
    func isPredicted(_ i: Int) -> Bool {
        if isAircraft { return false }
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
        if isAircraft, analysis?.track?.frames[currentFrame].hasData != true { sourceZoom = 1 }
        else if sourceZoom < 2 { sourceZoom = 4 }
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
                of = job.previewFrame(currentFrame)
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

    func addAudioTracks() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff, .movie]
        p.allowsMultipleSelection = true
        p.message = "添加独立音轨，可与背景音乐和快门声同时播放"
        if p.runModal() == .OK {
            for url in p.urls {
                var track = AudioTrack(); track.url = url
                audio.tracks.append(track)
            }
        }
    }

    func addShutter(_ assetID: String) {
        guard SoundLibrary.url(for: assetID) != nil else { return }
        var track = AudioTrack(); track.assetID = assetID
        audio.tracks.append(track)
    }

    private func audioChanged(from old: AudioSettings) {
        guard old != audio else { return }
        if !loading,analysis != nil { projectDirty=true;projectCloseApproved=false }
        if let d = try? JSONEncoder().encode(audio) { defaults.set(d, forKey: "audio.v1") }
        if old.url != audio.url { loadAudioOverview() }
        rebuildAudioPlayer()
    }

    private func loadAudioOverview() {
        audioOverviewTask?.cancel()
        audioOverview = nil
        musicCues = []
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
                    self.musicCues = MusicCues.analyze(peaks: o.peaks, binsPerSecond: o.binsPerSecond)
                    if self.audio.startOffset > o.duration { self.audio.startOffset = 0 }
                case .failure(let e): self.audioMessage = e.localizedDescription
                }
            }
        }
    }

    /// Rebuilds the preview player (same mix as the export) after music or duration changes.
    func rebuildAudioPlayer() {
        audioBuildTask?.cancel()
        guard let job, job.duration > 0, job.mixedAudio(audio).isActive else {
            audioPlayer?.pause(); audioPlayer = nil
            return
        }
        let s = job.mixedAudio(audio), duration = job.duration
        audioBuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)   // debounce slider drags
            do {
                try Task.checkCancellation()
                let (comp, mix) = try await AudioMixer.makeMix(s, duration: duration)
                try Task.checkCancellation()
                guard let self else { return }
                self.audioMessage = nil
                let item = AVPlayerItem(asset: comp)
                item.audioMix = mix
                if let p = self.audioPlayer { p.replaceCurrentItem(with: item) } else { self.audioPlayer = AVPlayer(playerItem: item) }
                if self.isPlaying, let job = self.job { self.startAudio(at: Double(self.playheadOutput) / job.export.outputFPS) }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.audioPlayer?.pause(); self.audioPlayer = nil
                self.audioMessage = "音频预览失败：" + error.localizedDescription
            }
        }
    }

    private func startAudio(at t: Double) {
        guard previewAudio, let p = audioPlayer else { return }
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
        if !loading,analysis != nil { projectDirty=true;projectCloseApproved=false }
        if let d = try? JSONEncoder().encode(watermark) { defaults.set(d, forKey: "watermark.v1") }
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
        guard let a = analysis, !exportState.running else { return }
        stop()
        // a fresh job with the latest settings plus the watermark (the preview job draws it separately)
        let job = RenderJob(analysis: a, composition: composition, look: look, export: exportSettings,
                            selection: selection, watermark: watermark)
        let music: AudioSettings? = kind == .video && audio.isActive ? audio : nil
        exportState = ExportState(running: true, progress: 0, message: "正在导出…", outputURL: url)
        let flag = CancelFlag(); exportCancel = flag
        Task.detached(priority: .userInitiated) { [weak self] in
            let cacheOperation=CachePolicy.beginOperation(root:ProxyCache.shared.root)
            defer { CachePolicy.endOperation(cacheOperation);Task { @MainActor [weak self] in self?.trimCache() } }
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
                Diagnostics.record("export \(kind.rawValue) complete seconds=\(dt)")
                CachePolicy.endOperation(cacheOperation)
                await MainActor.run {
                    self?.exportState.running = false
                    self?.exportState.progress = 1
                    self?.exportState.message = String(format: "导出完成（%.0f 秒）", dt) + (ex.warning.map { " · " + $0 } ?? "")
                    if kind == .video { self?.offerExportCleanup() }
                }
            } catch {
                Diagnostics.record("export \(kind.rawValue) failed: \(error)")
                await MainActor.run {
                    self?.exportState.running = false
                    self?.exportState.message = error.localizedDescription
                }
            }
        }
    }

    private var exportCancel = CancelFlag()
    func cancelExport() {
        guard exportState.running, !exportState.cancelling else { return }
        exportState.cancelling = true; exportCancel.cancel()
    }

    // MARK: - Persistence

    private struct Saved: Codable {
        var version: Int?
        var composition: Composition
        var look: LookSettings
        var export: ExportSettings
        var selection: FrameSelection
        var presetID: String?
        var subject: String?
        var profiles: [String: SubjectProfile]?
    }
    private static let settingsVersion = 3

    private var loading = false
    private func scheduleSettingsSave() {
        guard !loading else { return }
        settingsSaveWork?.cancel()
        subjectProfiles[subject.rawValue] = currentProfile.untrimmed
        let bird = (subjectProfiles["bird"] ?? currentProfile).untrimmed
        let s = Saved(version: Self.settingsVersion, composition: bird.composition, look: bird.look, export: bird.export,
                      selection: bird.selection, presetID: bird.presetID,subject: subject.rawValue,profiles: subjectProfiles.mapValues(\.untrimmed))
        let defaults = self.defaults
        let w = DispatchWorkItem {
            if let d = try? JSONEncoder().encode(s) { defaults.set(d, forKey: "settings.v1") }
        }
        settingsSaveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    private func loadSettings() {
        loading = true
        defer { loading = false }
        let ud = defaults
        if let d = ud.data(forKey: "settings.v1"), let s = try? JSONDecoder().decode(Saved.self, from: d) {
            var comp = s.composition
            // v2: the new "shift" edge handling replaces auto-zoom as the default
            if (s.version ?? 1) < 2 && comp.edgeFill == .autoZoom { comp.edgeFill = .shift }
            composition = comp; look = s.look; exportSettings = s.export
            var sel = s.selection; sel.trimStart = 0; sel.trimEnd = nil
            selection = sel; presetID = s.presetID
            subjectProfiles = (s.profiles ?? [:]).filter { AnalysisSubject(rawValue: $0.key) != nil }
            if subjectProfiles["bird"] == nil { subjectProfiles["bird"] = currentProfile }
            subject = AnalysisSubject(rawValue: s.subject ?? "bird") ?? .bird
            if subject == .aircraft, subjectProfiles["aircraft"] == nil {
                subjectProfiles["aircraft"] = .initialAircraft(from: subjectProfiles["bird"]!)
            }
            if let profile = subjectProfiles[subject.rawValue] { applyProfile(profile) }
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


extension AppState {
    var workspaceBusy: Bool {
        if exportState.running || phase == .importing { return true }
        if case .analyzing = phase { return true };return false
    }
    func projectSnapshot() throws -> WorkspaceDocument {
        guard let analysis,phase == .ready else { throw WorkspaceError.invalid("请先完成导入和分析，再保存工程。") }
        saveWork?.cancel();ProxyCache.shared.saveAnalysis(analysis)
        var profiles=subjectProfiles;profiles[subject.rawValue]=currentProfile
        return try WorkspaceDocument(frames:frames,segments:segments,analysis:analysis,remembered:ProxyCache.shared.rememberedAnalyses,
            subject:subject,profile:currentProfile,profiles:profiles,audio:audio,watermark:watermark,segmentIndex:segmentIndex,
            mergeGroups:mergeGroupIndices,currentFrame:currentFrame,viewMode:viewMode.rawValue,sourceZoom:sourceZoom,previewAudio:previewAudio)
    }
    func saveProject(to url: URL) throws {
        try projectSnapshot().save(to:url,cacheRoot:ProxyCache.shared.root)
        projectURL=url;projectDirty=false;projectCloseApproved=false
    }
    @discardableResult func saveProjectPanel(asCopy: Bool = false) -> Bool {
        guard analysis != nil,!workspaceBusy else { return false }
        var file=asCopy ? nil : projectURL
        if file == nil {
            let panel=NSSavePanel();panel.allowedContentTypes=[UTType(filenameExtension:"birdlock") ?? .json]
            let source=VideoSource.originalURL(frames:frames) ?? frames.first?.url
            panel.nameFieldStringValue=(source?.deletingPathExtension().lastPathComponent ?? "BirdLock")+"_工程.birdlock"
            panel.directoryURL=source?.deletingLastPathComponent()
            guard panel.runModal() == .OK else { return false };file=panel.url
        }
        do { if let file { try saveProject(to:file);return true } }
        catch { let alert=NSAlert();alert.messageText="工程未保存";alert.informativeText=error.localizedDescription;alert.runModal() }
        return false
    }
    func confirmCanLeave() -> Bool {
        if workspaceBusy { let alert=NSAlert();alert.messageText="任务进行中";alert.informativeText="请先完成或取消当前导入、分析或导出。";alert.runModal();return false }
        guard projectDirty,analysis != nil else { return true }
        let alert=NSAlert();alert.messageText="保存工程？";alert.informativeText="当前编辑尚未保存到工程文件。是否先保存？"
        alert.addButton(withTitle:"保存");alert.addButton(withTitle:"取消");alert.addButton(withTitle:"不保存")
        switch alert.runModal() { case .alertFirstButtonReturn:return saveProjectPanel();case .alertThirdButtonReturn:return true;default:return false }
    }
    func openProjectPanel(_ proposed: URL? = nil) {
        var url=proposed
        if url == nil {
            let panel=NSOpenPanel();panel.allowedContentTypes=[UTType(filenameExtension:"birdlock") ?? .json];panel.allowsMultipleSelection=false
            guard panel.runModal() == .OK else { return };url=panel.url
        }
        guard let url else { return }
        do {
            let document: WorkspaceDocument
            do { document=try WorkspaceDocument.read(from:url) }
            catch WorkspaceError.missing(let paths) {
                let alert=NSAlert();alert.messageText="重新定位素材";alert.informativeText=paths.prefix(8).joined(separator:"\n")+"\n请选择原片所在的文件夹。";alert.runModal()
                let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true
                guard panel.runModal() == .OK,let folder=panel.url else { return }
                document=try WorkspaceDocument.read(from:url,relocation:folder)
            }
            guard confirmCanLeave() else { return };openProject(url,document:document)
        } catch { let alert=NSAlert();alert.messageText="无法打开工程";alert.informativeText=error.localizedDescription;alert.runModal() }
    }
    func openProject(_ url: URL, document: WorkspaceDocument) {
        stop();analysisTask?.cancel();cancelFlag.cancel();importGeneration+=1
        let generation=importGeneration,flag=CancelFlag();cancelFlag=flag
        phase = .importing;importMessage="正在打开工程，按需恢复过程文件…"
        analysisTask=Task.detached(priority:.userInitiated) { [weak self] in
            let cacheOperation=CachePolicy.beginOperation(root:ProxyCache.shared.root)
            defer { CachePolicy.endOperation(cacheOperation);Task { @MainActor [weak self] in self?.trimCache() } }
            do {
                let restored=try document.restoreMedia(cache:.shared,isCancelled:{flag.isCancelled},progress:{ progress in
                    Task { @MainActor in
                        guard let self,generation==self.importGeneration,!flag.isCancelled else { return }
                        self.importMessage="正在恢复工程过程文件… \(Int(progress*100))%"
                    }
                })
                await MainActor.run {
                    guard let self,generation==self.importGeneration,!flag.isCancelled else { return }
                    self.loading=true;self.jobGeneration+=1;self.rebuildWork?.cancel();self.saveWork?.cancel()
                    self.job=nil;self.frames=restored.frames;ProxyCache.shared.retainRecords(frames:restored.frames);self.segments=restored.segments.map { BurstSegment(range:$0.start..<($0.start+$0.count),fps:$0.fps) }
                    self.segmentIndex=restored.segmentIndex;self.mergeGroupIndices=restored.mergeGroups
                    self.analysis=restored.analyses[0];self.subject=restored.subject;self.subjectProfiles=restored.profiles
                    self.applyProfile(restored.profile,resetTrim:false);self.audio=restored.audio;self.watermark=restored.watermark
                    self.currentFrame=clamp(restored.currentFrame,0,self.analysis!.count-1);self.viewMode=ViewMode(rawValue:restored.viewMode) ?? .output
                    self.sourceZoom=restored.sourceZoom;self.previewAudio=restored.previewAudio;self.sourceTool = .none;self.subjectRollback=nil
                    self.previewImage=nil;self.sourceImage=nil;self.sourceDetail=nil;self.engine.clear()
                    self.phase = .ready;self.projectURL=url;self.projectDirty=false;self.projectCloseApproved=false
                    self.timelineMessage="工程已恢复，可继续编辑。"+((restored.missingAssets ?? []).isEmpty ? "" : "部分音频或水印素材缺失，请重新选择。");self.loading=false
                    self.scheduleSettingsSave();self.rebuildJob(immediate:true);self.trimCache()
                }
            } catch {
                await MainActor.run {
                    guard let self,generation==self.importGeneration,!flag.isCancelled else { return }
                    self.phase=self.analysis == nil ? .empty : .ready;self.timelineMessage=error.localizedDescription
                }
            }
        }
    }
    func closeProject() {
        stop();cancelAnalysis();analysisTask?.cancel();rebuildWork?.cancel();saveWork?.cancel();jobGeneration+=1
        loading=true
        frames=[];segments=[];mergeGroupIndices=[];analysis=nil;job=nil;previewImage=nil;sourceImage=nil;sourceDetail=nil
        audio.tracks.removeAll { $0.videoOriginal };engine.clear();phase = .empty;projectURL=nil;projectDirty=false;subjectRollback=nil
        loading=false;ProxyCache.shared.retainRecords(frames:[]);CachePolicy.protect(owner:cacheOwner,roots:[])
    }
    var protectedCache: Set<String> {
        var roots=Set(frames.map { $0.url.deletingLastPathComponent().path })
        if let analysis { roots.insert(ProxyCache.shared.root.appendingPathComponent(analysis.fingerprint).path);roots.insert(ProxyCache.shared.root.appendingPathComponent("video-audio").path) }
        return roots
    }
    func trimCache() {
        CachePolicy.protect(owner:cacheOwner,roots:protectedCache)
        guard cacheLimitGB>0 else { return }
        let limit=cacheLimitGB*(1<<30),protected=protectedCache
        Task.detached(priority:.utility) { [weak self] in
            let report=CachePolicy.clean(root:ProxyCache.shared.root,limitBytes:limit,protected:protected)
            await MainActor.run {
                self?.cacheMessage=report.overLimit ? "当前任务或保留记录超过缓存上限，可在关闭工程后清理。" : String(format:"缓存占用 %.2f GB",Double(report.after)/Double(1<<30))
            }
        }
    }
    func cleanCurrentVideo() -> CacheCleanup {
        let roots=Set(frames.map { $0.url.deletingLastPathComponent().path })
        closeProject()
        return CachePolicy.clean(root:ProxyCache.shared.root,onlyVideos:roots)
    }
    func offerExportCleanup() {
        guard askCleanupAfterExport,isVideoProject else { return }
        let alert=NSAlert();alert.messageText="视频已导出";alert.informativeText="是否保存工程并清理本次视频的过程文件？清理后将关闭当前工作，保留原片和导出视频。下次打开工程时按需重新生成视频帧，沿用保存的识别结果与编辑。"
        alert.addButton(withTitle:"保留过程文件");alert.addButton(withTitle:"保存工程并清理")
        guard alert.runModal() == .alertSecondButtonReturn,saveProjectPanel() else { return }
        let report=cleanCurrentVideo(),done=NSAlert();done.messageText="过程文件已清理"
        done.informativeText=String(format:"已释放 %.2f GB。工程、原片和导出视频保留。",Double(report.removed)/Double(1<<30))+(report.failures>0 ? "部分文件正被占用，可稍后重试。" : "")
        done.runModal()
    }
}
