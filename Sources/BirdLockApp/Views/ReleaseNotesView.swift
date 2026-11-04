import SwiftUI

struct ReleaseNotesView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing:0) {
            HStack { Text("BirdLock 1.10.0 更新说明").font(.title2.bold());Spacer() }.padding(20)
            Divider()
            ScrollView { MarkdownDocView(text:AppDocs.text("更新说明-1.10.0.md")).padding(24) }
            Divider()
            HStack { Text("可在帮助菜单再次查看").font(.caption).foregroundStyle(.secondary);Spacer()
                Button("开始使用") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(16)
        }.frame(width:700,height:620)
    }
}
