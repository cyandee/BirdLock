import Foundation

public struct VideoRecipe: Codable, Sendable {
    public var sourcePath: String
    public var bytes: Int
    public var modified: Double
    public var width: Int
    public var height: Int
    public var start: Double
    public var seconds: Double
    public var fps: Double
    public var count: Int
    public var lensJSON: String?
}
public struct ProjectVideo: Codable, Sendable {
    public var cacheDirectory: String
    public var recipe: VideoRecipe
    public var motion: VideoMotionRecord?
}
public struct ProjectSegment: Codable, Sendable {
    public var start: Int
    public var count: Int
    public var fps: Double
    public init(_ segment: BurstSegment) { start=segment.range.lowerBound;count=segment.range.count;fps=segment.fps }
}
public struct ProjectLocation: Codable, Sendable {
    public var path: String
    public var relative: String
    public var bytes: Int?
    public var required: Bool
}
public enum WorkspaceError: LocalizedError {
    case invalid(String)
    case missing([String])
    public var errorDescription: String? {
        switch self { case .invalid(let text): return text;case .missing(let paths):return "找不到工程素材：\n"+paths.prefix(8).joined(separator:"\n") }
    }
}

/// Shared .birdlock wire format. Originals remain external; observations and edits live in this file.
public struct WorkspaceDocument: Codable, Sendable {
    public var format = "BirdLockProject"
    public var schema = 1
    public var creatorVersion = "1.10.0"
    public var subject: AnalysisSubject
    public var frames: [SourceFrame]
    public var segments: [ProjectSegment]
    public var segmentIndex: Int
    public var mergeGroups: [Int]
    public var analyses: [SequenceAnalysis]
    public var profile: SubjectProfile
    public var profiles: [String:SubjectProfile]
    public var audio: AudioSettings
    public var watermark: WatermarkSettings
    public var videos: [ProjectVideo]
    public var currentFrame: Int
    public var viewMode: String
    public var sourceZoom: Double
    public var previewAudio: Bool
    public var locations: [ProjectLocation] = []
    public var missingAssets: [String]? = nil
    public static let maxBytes = 128 << 20

    public init(frames: [SourceFrame], segments: [BurstSegment], analysis: SequenceAnalysis, remembered: [SequenceAnalysis],
                subject: AnalysisSubject, profile: SubjectProfile, profiles: [String:SubjectProfile], audio: AudioSettings,
                watermark: WatermarkSettings, segmentIndex: Int, mergeGroups: [Int], currentFrame: Int, viewMode: String,
                sourceZoom: Double, previewAudio: Bool) throws {
        self.frames=frames;self.segments=segments.map(ProjectSegment.init);self.subject=subject;self.profile=profile
        self.profiles=profiles;self.audio=audio;self.watermark=watermark;self.segmentIndex=segmentIndex;self.mergeGroups=mergeGroups
        self.currentFrame=currentFrame;self.viewMode=viewMode;self.sourceZoom=sourceZoom;self.previewAudio=previewAudio
        let master=Set(frames.map(\.url));analyses=[analysis]
        analyses += remembered.filter { $0.fingerprint != analysis.fingerprint && !$0.frames.isEmpty && $0.frames.allSatisfy { master.contains($0.url) } }
        for i in analyses.indices { analyses[i].track=nil }
        videos=[]
        for root in Set(frames.map { $0.url.deletingLastPathComponent() }) {
            if FileManager.default.fileExists(atPath:root.appendingPathComponent("video-source.json").path) {
                guard let raw=try? Data(contentsOf:root.appendingPathComponent("video-recipe.json")), let recipe=try? JSONDecoder().decode(VideoRecipe.self,from:raw) else {
                    throw WorkspaceError.invalid("请重新导入一次该视频，记录原片与镜头参数后再保存工程。")
                }
                let motion=(try? Data(contentsOf:root.appendingPathComponent("motion.json"))).flatMap { try? JSONDecoder().decode(VideoMotionRecord.self,from:$0) }
                videos.append(ProjectVideo(cacheDirectory:root.path,recipe:recipe,motion:motion))
            }
        }
    }

    private static func relative(_ source: URL, to parent: URL) -> String {
        let a=source.standardizedFileURL.pathComponents,b=parent.standardizedFileURL.pathComponents
        var count=0;while count<min(a.count,b.count) && a[count]==b[count] { count+=1 }
        return (Array(repeating:"..",count:b.count-count)+Array(a.dropFirst(count))).joined(separator:"/")
    }
    public func save(to url: URL, cacheRoot: URL) throws {
        let resolved=url.resolvingSymlinksInPath().standardizedFileURL.path
        let cache=cacheRoot.resolvingSymlinksInPath().standardizedFileURL.path+"/"
        guard !resolved.hasPrefix(cache) else { throw WorkspaceError.invalid("工程文件请保存在缓存文件夹之外。") }
        var copy=self;copy.missingAssets=nil;var paths:[String:Bool]=[:]
        let videoRoots=Set(videos.map(\.cacheDirectory))
        for frame in frames where !videoRoots.contains(frame.url.deletingLastPathComponent().path) { paths[frame.url.path]=true }
        for video in videos { paths[video.recipe.sourcePath]=true }
        for track in audio.tracks where !track.videoOriginal { if let url=track.url { paths[url.path]=paths[url.path] ?? false } }
        if let url=audio.url { paths[url.path]=paths[url.path] ?? false }
        if let path=watermark.imagePath,!path.isEmpty { paths[path]=paths[path] ?? false }
        copy.locations=paths.sorted(by:{$0.key<$1.key}).map { path,required in
            let file=URL(fileURLWithPath:path)
            return ProjectLocation(path:path,relative:Self.relative(file,to:url.deletingLastPathComponent()),bytes:try? file.resourceValues(forKeys:[.fileSizeKey]).fileSize,required:required)
        }
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let data=try encoder.encode(copy)
        guard data.count <= Self.maxBytes else { throw WorkspaceError.invalid("工程过大，请拆分素材后保存。") }
        try data.write(to:url,options:.atomic)
    }
    private static func wireURI(_ path: String) -> String {
        if path.replacingOccurrences(of:"\\",with:"/").hasPrefix("//") { return "file:"+path.replacingOccurrences(of:"\\",with:"/").addingPercentEncoding(withAllowedCharacters:.urlPathAllowed)! }
        if path.count>2, path[path.index(after:path.startIndex)]==":" {
            return "file:///" + path.replacingOccurrences(of:"\\",with:"/").addingPercentEncoding(withAllowedCharacters:.urlPathAllowed)!
        }
        return URL(fileURLWithPath:path).absoluteString
    }
    private static func replace(_ value: Any, mapping: [String:String]) -> Any {
        if let text=value as? String { return mapping[text] ?? text }
        if let array=value as? [Any] { return array.map { replace($0,mapping:mapping) } }
        if let object=value as? [String:Any] { return object.mapValues { replace($0,mapping:mapping) } }
        return value
    }
    public static func read(from url: URL, relocation: URL? = nil) throws -> WorkspaceDocument {
        guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) <= maxBytes else { throw WorkspaceError.invalid("工程文件超出支持大小。") }
        let data=try Data(contentsOf:url)
        guard let raw=try JSONSerialization.jsonObject(with:data) as? [String:Any],raw["format"] as? String == "BirdLockProject",raw["schema"] as? Int == 1 else {
            throw WorkspaceError.invalid("不支持的工程格式或版本。")
        }
        let locations=raw["locations"] as? [[String:Any]] ?? [];var missing:[String]=[],optionalMissing:[String]=[],mapping:[String:String]=[:]
        for location in locations {
            guard let old=location["path"] as? String,let savedRelative=location["relative"] as? String else { throw WorkspaceError.invalid("工程素材引用无效。") }
            let relative=savedRelative.replacingOccurrences(of:"\\",with:"/")
            var candidates=[URL(fileURLWithPath:old),url.deletingLastPathComponent().appendingPathComponent(relative)]
            if let relocation {
                candidates += [relocation.appendingPathComponent(old.replacingOccurrences(of:"\\",with:"/").split(separator:"/").last.map(String.init) ?? old),relocation.appendingPathComponent(relative)]
            }
            let expected=location["bytes"] as? Int
            if let file=candidates.first(where: { file in
                guard let size=try? file.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey]),size.isRegularFile==true else { return false }
                return expected == nil || size.fileSize==expected
            }) {
                mapping[old]=file.standardizedFileURL.path;mapping[wireURI(old)]=file.standardizedFileURL.absoluteString
            } else if location["required"] as? Bool != false { missing.append(old) } else { optionalMissing.append(old) }
        }
        if !missing.isEmpty { throw WorkspaceError.missing(missing) }
        let translated=try JSONSerialization.data(withJSONObject:replace(raw,mapping:mapping))
        var document=try JSONDecoder().decode(WorkspaceDocument.self,from:translated)
        document.missingAssets=optionalMissing
        try document.validate();return document
    }
    public func validate() throws {
        guard !frames.isEmpty,frames.count<=100000,!analyses.isEmpty else { throw WorkspaceError.invalid("工程缺少有效画面或识别记录。") }
        for segment in segments {
            guard segment.start>=0,segment.count>0,segment.start+segment.count<=frames.count,segment.fps>0,segment.fps<=1000 else { throw WorkspaceError.invalid("工程分组范围无效。") }
        }
        for a in analyses {
            guard (a.eyeSelections ?? []).allSatisfy({ a.frames.indices.contains($0.frame) && ["left_eye","right_eye"].contains($0.side) }),
                  (a.customSeeds ?? []).allSatisfy({ CustomTracking.valid($0,frames:a.frames) }) else { throw WorkspaceError.invalid("工程跟踪参考记录无效。") }
            let master=Set(frames.map(\.url))
            guard a.frames.allSatisfy({ master.contains($0.url) }) else { throw WorkspaceError.invalid("工程识别记录引用了其他素材。") }
            for (index,frame) in a.perFrame.enumerated() {
                guard frame.index==index,frame.head.points.count==6,frame.head.conf.count==6,
                      frame.target == nil || (frame.target!>=0 && frame.target!<frame.birds.count) else { throw WorkspaceError.invalid("工程主体或头部记录无效。") }
            }
            for shot in a.closeups ?? [] {
                guard shot.frame>=0,shot.endFrame>=shot.frame,shot.endFrame<a.count,shot.seconds>0,shot.seconds<=3600 else { throw WorkspaceError.invalid("工程特写范围无效。") }
            }
            guard !a.frames.isEmpty,a.perFrame.count==a.count,a.fps>0,a.fps<=1000,
                  a.manualEye.keys.allSatisfy(a.frames.indices.contains),a.excluded.allSatisfy(a.frames.indices.contains) else { throw WorkspaceError.invalid("工程编辑或识别记录不完整。") }
        }
        guard segmentIndex == -1 || segments.indices.contains(segmentIndex),Set(mergeGroups).count==mergeGroups.count,mergeGroups.allSatisfy(segments.indices.contains) else { throw WorkspaceError.invalid("工程分组选择无效。") }
        let chosen=segmentIndex == -1 ? mergeGroups : [segmentIndex]
        let active=chosen.flatMap { i in Array(frames[segments[i].start..<(segments[i].start+segments[i].count)]) }.map(\.url)
        guard active==analyses[0].frames.map(\.url) else { throw WorkspaceError.invalid("工程当前分组与识别记录不一致。") }
    }
    private static func mediaPath(_ url:URL) -> String {
        if let host=url.host,!host.isEmpty,host != "localhost" { return "//"+host+url.path };return url.path
    }
    private static func comparable(_ path: String) -> String {
        var s=path.replacingOccurrences(of:"\\",with:"/")
        if s.hasPrefix("/"),s.count>3,s[s.index(s.startIndex,offsetBy:2)]==":" { s.removeFirst() }
        return s
    }
    public func restoreMedia(cache: ProxyCache, isCancelled: @escaping @Sendable () -> Bool = {false}, progress: @escaping @Sendable (Double) -> Void = {_ in}) throws -> WorkspaceDocument {
        var document=self;var replacements:[String:SourceFrame]=[:]
        for video in videos {
            let recipe=video.recipe,source=URL(fileURLWithPath:recipe.sourcePath)
            let temporary=FileManager.default.temporaryDirectory.appendingPathComponent("birdlock-project-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:temporary) }
            var options=VideoImportOptions();options.start=recipe.start;options.seconds=recipe.seconds;options.fps=recipe.fps
            if let json=recipe.lensJSON { let file=temporary.appendingPathComponent("lens.json");try Data(json.utf8).write(to:file);options.profile=file }
            let result=try VideoImporter.extract(source,options:options,root:cache.root.appendingPathComponent("video-imports"),progress:progress,isCancelled:isCancelled)
            guard result.frames.count==recipe.count else { throw WorkspaceError.invalid("原视频已变化，不能恢复同一组画面。") }
            if let motion=video.motion { try VideoStabilization.save(motion,frames:result.frames) }
            else { _ = try VideoStabilization.prepare(frames:result.frames,video:source,start:recipe.start,fps:result.fps,profile:options.profile,isCancelled:isCancelled) }
            for frame in frames where Self.comparable(Self.mediaPath(frame.url.deletingLastPathComponent()))==Self.comparable(video.cacheDirectory) {
                guard let ordinal=Int(frame.url.deletingPathExtension().lastPathComponent.split(separator:"-").last ?? ""),result.frames.indices.contains(ordinal) else { throw WorkspaceError.invalid("工程视频帧编号无效。") }
                let new=result.frames[ordinal]
                guard new.pixelWidth==frame.pixelWidth,new.pixelHeight==frame.pixelHeight else { throw WorkspaceError.invalid("原视频画面尺寸已变化。") }
                replacements[frame.url.absoluteString]=new
            }
        }
        func mapped(_ frame:SourceFrame) -> SourceFrame {
            guard let new=replacements[frame.url.absoluteString] else { return frame }
            var frame=frame;frame.url=new.url;frame.fileSize=new.fileSize;frame.modified=new.modified;return frame
        }
        document.frames=frames.map(mapped)
        guard document.frames.allSatisfy({ FileManager.default.fileExists(atPath:$0.url.path) }) else { throw WorkspaceError.invalid("工程素材无法读取，请重新定位原片。") }
        for i in document.analyses.indices {
            document.analyses[i].frames=analyses[i].frames.map(mapped)
            document.analyses[i].fingerprint=Analyzer.fingerprint(document.analyses[i].frames,aircraftModelIdentity:analyses[i].analysisSubject == .aircraft ? analyses[i].modelIdentity : nil,custom:analyses[i].analysisSubject == .custom)
            document.analyses[i].track=TrackBuilder.build(document.analyses[i]);cache.saveAnalysis(document.analyses[i])
        }
        return document
    }
}
