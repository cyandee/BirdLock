import SwiftUI
import BirdLockCore

struct AudioTracksCard: View {
    @Environment(AppState.self) private var state
    @State private var soundID = "sony-a1m2-30"

    var body: some View {
        @Bindable var state = state
        InspectorCard(title: "音效与多轨", icon: "waveform") {
            CameraSoundPicker(assetID: $soundID)
            HStack {
                Button("添加快门声") { state.addShutter(soundID) }
                Button("添加音频…") { state.addAudioTracks() }
            }.controlSize(.small)
            Text("快门与背景音乐同时播放；各轨可独立静音、调音量、起点、长度和淡入淡出。长度为 0 时延续至视频结束。混音自动预留音量余量。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach($state.audio.tracks) { $track in
                Divider()
                AudioTrackEditor(track: $track) {
                    let id = track.id
                    state.audio.tracks.removeAll { $0.id == id }
                }
            }
            if let message = state.audioMessage, state.audio.url == nil {
                StatusNote(text: message, icon: "exclamationmark.triangle", color: Theme.warn)
            }
        }
    }
}

private struct AudioTrackEditor: View {
    @Binding var track: AudioTrack
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(track.title).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(action: remove) { Image(systemName: "trash") }.help("移除这条音轨")
            }.font(.callout)
            if track.assetID != nil {
                CameraSoundPicker(assetID: Binding(get: { track.assetID ?? "" }, set: { track.assetID = $0 }))
            }
            Toggle("静音", isOn: $track.muted)
            Toggle("循环播放", isOn: $track.loop)
            LabeledSlider(title: "音量", value: $track.volume, range: 0...1.5, format: { String(format: "%.0f%%", $0 * 100) })
            number("视频起点", value: $track.timelineStart)
            number("播放长度", value: $track.duration)
            number("素材起点", value: $track.startOffset)
            LabeledSlider(title: "淡入", value: $track.fadeIn, range: 0...5, step: 0.1, format: { String(format: "%.1f 秒", $0) })
            LabeledSlider(title: "淡出", value: $track.fadeOut, range: 0...5, step: 0.1, format: { String(format: "%.1f 秒", $0) })
            if track.sourceURL.map({ FileManager.default.fileExists(atPath: $0.path) }) != true {
                Text("找不到该音频文件，请重新添加。").font(.caption).foregroundStyle(Theme.warn)
            }
        }
    }

    private func number(_ label: String, value: Binding<Double>) -> some View {
        FormRow(label: label) {
            TextField("秒", value: value, format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder).frame(width: 80)
                .onChange(of: value.wrappedValue) { _, v in
                    if !v.isFinite || v < 0 { value.wrappedValue = 0 }
                }
            Text("秒").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Camera first, recording second; legacy saved IDs resolve without exposing duplicate menu entries.
struct CameraSoundPicker: View {
    @Binding var assetID: String
    private var camera: String { SoundLibrary.asset(for: assetID)?.cameraID ?? SoundLibrary.cameras.first ?? "" }
    var body: some View {
        Picker("相机", selection: Binding(get: { camera }, set: { value in
            assetID = SoundLibrary.burstAssets.first(where: { $0.cameraID == value })?.id ?? ""
        })) {
            ForEach(SoundLibrary.cameras, id: \.self) { id in
                Text(SoundLibrary.burstAssets.first(where: { $0.cameraID == id })?.camera ?? id).tag(id)
            }
        }
        Picker("fps / 录音", selection: Binding(get: { SoundLibrary.canonicalID(assetID) }, set: { assetID = $0 })) {
            if SoundLibrary.asset(for: assetID) == nil { Text("请选择录音").tag(assetID) }
            ForEach(SoundLibrary.burstAssets.filter { $0.cameraID == camera }) { Text($0.variant).tag($0.id) }
        }
    }
}
