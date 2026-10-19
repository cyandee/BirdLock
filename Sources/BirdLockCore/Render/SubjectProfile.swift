import Foundation

/// Independent visual/export choices for each subject; audio and imported photos remain project-wide.
public struct SubjectProfile: Codable, Sendable {
    public var composition: Composition
    public var look: LookSettings
    public var export: ExportSettings
    public var selection: FrameSelection
    public var presetID: String?

    public init(composition: Composition, look: LookSettings, export: ExportSettings, selection: FrameSelection, presetID: String?) {
        self.composition = composition; self.look = look; self.export = export; self.selection = selection; self.presetID = presetID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        composition = c.value(.composition,Composition());look = c.value(.look,LookSettings())
        export = c.value(.export,ExportSettings());selection = c.value(.selection,FrameSelection())
        presetID = try? c.decodeIfPresent(String.self,forKey: .presetID)
    }

    public var untrimmed: SubjectProfile {
        var copy = self;copy.selection.trimStart = 0;copy.selection.trimEnd = nil
        return copy
    }

    public static func initialAircraft(from bird: SubjectProfile) -> SubjectProfile {
        var profile = bird.untrimmed
        profile.composition = CompositionPreset.aircraft[1].composition
        profile.presetID = "aircraft-lead"
        profile.export.aspect = AspectRatio(w: 16,h: 9,label: "16:9")
        profile.export.focusMark.enabled = true
        profile.export.focusMark.showEye = false;profile.export.focusMark.showHead = true;profile.export.focusMark.showBody = true
        return profile
    }
}

public extension CompositionPreset {
    static func forSubject(_ subject: AnalysisSubject) -> [CompositionPreset] { subject == .bird ? all : aircraft }

    static let aircraft: [CompositionPreset] = {
        func base() -> Composition {
            var c = Composition();c.lockPoint = .headCenter;c.anchorX = 0.65;c.anchorY = 0.5;c.framing = 20;c.edgeFill = .blurExtend
            return c
        }
        var result: [CompositionPreset] = [], c = base()
        c.anchorX = 0.5;c.autoLeadRoom = false
        result.append(.init(id: "aircraft-center",name: "机头居中",detail: "机头保持在画面正中",composition: c))
        c = base()
        result.append(.init(id: "aircraft-lead",name: "全机留白",detail: "为机身和飞行方向都保留空间",composition: c))
        c = base();c.anchorX = 0.5;c.autoLeadRoom = false;c.framing = 7
        result.append(.init(id: "aircraft-closeup",name: "机头特写",detail: "收紧取景，突出机头",composition: c))
        c = base();c.framing = 28
        result.append(.init(id: "aircraft-wide",name: "宽松全机",detail: "展示机身、机翼和周围环境",composition: c))
        c = base();c.followSoftness = 0.45
        result.append(.init(id: "aircraft-follow",name: "柔和跟随",detail: "镜头平缓跟随飞机",composition: c))
        c = base();c.sizeMode = .fixedCrop
        result.append(.init(id: "aircraft-natural",name: "自然远近",detail: "飞机大小随距离自然变化",composition: c))
        return result
    }()
}
