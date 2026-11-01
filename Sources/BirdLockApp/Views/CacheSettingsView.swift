import SwiftUI
import BirdLockCore

struct CacheSettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var limit = 20
    @State private var ask = true
    @State private var usage = "正在统计缓存…"
    @State private var busy = false
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("缓存管理").font(.title2.bold())
            Text(usage).font(.callout)
            HStack {
                Text("缓存上限")
                TextField("GB",value:$limit,format:.number).frame(width:90).textFieldStyle(.roundedBorder)
                Text("GB · 0 表示不限制").foregroundStyle(.secondary)
            }
            Toggle("视频导出后询问是否保存工程并清理过程文件",isOn:$ask)
            Text("优先清理较久未使用、可从原片重建的文件。当前任务、工程和编辑记录受保护；保护内容超出上限时会保留并提示。").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if !state.cacheMessage.isEmpty { Text(state.cacheMessage).font(.caption).foregroundStyle(.secondary) }
            Button("清理未使用的过程文件") {
                let protected=state.protectedCache;busy=true
                Task {
                    let report=await Task.detached { CachePolicy.clean(root:ProxyCache.shared.root,protected:protected) }.value
                    usage=String(format:"缓存占用 %.2f GB，已释放 %.2f GB",Double(report.after)/Double(1<<30),Double(report.removed)/Double(1<<30));busy=false
                }
            }.disabled(busy || state.workspaceBusy)
            HStack { Spacer();Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { state.cacheLimitGB=limit;state.askCleanupAfterExport=ask;state.trimCache();dismiss() }.keyboardShortcut(.defaultAction).disabled(busy || !(0...4096).contains(limit))
            }
        }.padding(24).frame(width:460)
        .task {
            limit=state.cacheLimitGB;ask=state.askCleanupAfterExport
            let bytes=await Task.detached { CachePolicy.totalSize(ProxyCache.shared.root) }.value
            usage=String(format:"当前缓存占用 %.2f GB",Double(bytes)/Double(1<<30))
        }
    }
}
