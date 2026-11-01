import SwiftUI
import BirdLockCore
import UniformTypeIdentifiers

struct VideoImportSheet: View {
    @Environment(AppState.self) private var state
    let url: URL
    @State private var info: VideoInfo?
    @State private var options = VideoImportOptions()
    @State private var profileName = ""
    @State private var cameraName = ""
    @State private var catalog: [LensCatalogEntry] = []
    @State private var searching = false
    @State private var searchResults = 0
    @State private var profileEdited = false
    @State private var matchMessage = ""
    @State private var showHelp = false
    @State private var message = "正在读取视频信息…"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导入视频（实验）").font(.title2.bold())
            Text(url.lastPathComponent).lineLimit(2)
            if let info {
                Text("\(info.width) × \(info.height) · \(String(format:"%.3f",info.fps)) fps · \(String(format:"%.2f",info.duration)) 秒").foregroundStyle(.secondary)
                Form {
                    TextField("片段起点（秒）", value: $options.start, format: .number)
                    TextField("片段时长（秒）", value: $options.seconds, format: .number)
                    TextField("采样帧率（1–60）", value: $options.fps, format: .number)
                }
                if !cameraName.isEmpty { Text(cameraName).font(.callout).fixedSize(horizontal: false, vertical: true) }
                VStack(alignment: .leading, spacing: 6) {
                    Text("镜头配置（可选）").font(.callout)
                    SearchableLensPicker(entries:catalog, selectedURL:options.profile, selectedName:profileName,
                        onSelect: { file in
                            profileEdited = true; searching = false
                            guard let file else { options.profile = nil; profileName = ""; message = ""; return true }
                            return selectProfile(file)
                        }, onSearch: { active, count in
                            searching = active; searchResults = count
                            if active { profileEdited = true }
                        }).frame(height: 26)
                    if searching && searchResults == 0 { Text("没有匹配的配置，可换关键词或点「查找配置」。").font(.caption).foregroundStyle(.secondary) }
                }
                HStack {
                    Button("导入镜头配置…") { chooseProfile() }
                    Button("清除配置") { profileEdited = true; searching = false; options.profile = nil; profileName = "" }.disabled(options.profile == nil)
                    Spacer()
                    Button("查找配置") { showHelp.toggle() }
                }
                if options.profile == nil, !matchMessage.isEmpty { Text(matchMessage).font(.caption).foregroundStyle(.secondary) }
                if showHelp {
                    Text(LensCatalog.helpText).font(.caption).fixedSize(horizontal: false, vertical: true)
                    HStack { Link("镜头配置库", destination: LensCatalog.databaseURL); Link("镜头标定教程", destination: LensCatalog.calibrationURL) }
                }
            }
            if let info {
                if let error = selectionError { Text(error).font(.caption).foregroundStyle(.orange) }
                else if let clip = try? VideoImporter.selection(info:info, options:options) {
                    Text(String(format:"片段 %.2f–%.2f 秒 · %d 帧 · %.3f fps",options.start,options.start+clip.seconds,clip.count,clip.fps)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("取消") { state.videoImportURL = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("导入并分析") {
                    state.videoImportURL = nil
                    state.importVideo(url, options: options)
                }.buttonStyle(.borderedProminent).disabled(info == nil || selectionError != nil || searching)
            }
        }.padding(24).frame(width: 510)
        .task {
            do {
                let result = try await Task.detached { try VideoImporter.probe(url) }.value
                info = result; options.seconds = min(10, result.duration); options.fps = max(1,min(30, result.fps)); message = ""
                catalog = try LensCatalog.entries()
                let match = try await Task.detached { try LensCatalog.detect(video: url, width: result.width, height: result.height, fps: result.fps) }.value
                applyMatch(match, automatic:true)
            } catch { message = error.localizedDescription }
        }
    }

    private var selectionError: String? {
        guard let info else { return nil }
        do { _ = try VideoImporter.selection(info:info, options:options); return nil }
        catch { return error.localizedDescription }
    }

    private func chooseProfile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json, .xml]
        guard panel.runModal() == .OK, let file = panel.url else { return }
        profileEdited = true; searching = false
        do {
            if file.pathExtension.lowercased() == "xml" {
                let match = try LensCatalog.importXML(file, width: info?.width, height: info?.height, fps: info?.fps)
                applyMatch(match); message = ""
            } else { selectProfile(file) }
        } catch { message = error.localizedDescription }
    }

    private func applyMatch(_ match: LensMatch, automatic: Bool = false) {
        cameraName = match.metadata.displayName; matchMessage = match.message
        guard !automatic || !profileEdited else { return }
        options.profile = match.selectedURL; profileName = match.selected?.title ?? ""
    }

    @discardableResult private func selectProfile(_ file: URL) -> Bool {
        do {
            let profile = try LensProfile.load(file)
            if let info { try profile.validate(width: info.width, height: info.height) }
            options.profile = file; profileName = catalog.first(where: { $0.url == file })?.title ?? profile.name; message = ""; return true
        } catch { message = error.localizedDescription; return false }
    }
}
