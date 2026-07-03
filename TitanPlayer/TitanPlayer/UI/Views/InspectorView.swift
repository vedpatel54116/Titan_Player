import SwiftUI
import CoreMedia

struct InspectorView: View {
    @EnvironmentObject var session: PlaybackSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let info = session.mediaInfo {
                Section {
                    InfoRow(label: "Format", value: info.format)
                    InfoRow(label: "Duration", value: formatDuration(info.duration))
                    ForEach(info.videoTracks.indices, id: \.self) { i in
                        let t = info.videoTracks[i]
                        InfoRow(label: "Video \(i+1)", value: "\(t.codec) \(t.width)x\(t.height)")
                    }
                    ForEach(info.audioTracks.indices, id: \.self) { i in
                        let t = info.audioTracks[i]
                        InfoRow(label: "Audio \(i+1)", value: "\(t.codec) \(t.channels)ch")
                    }
                } header: { Text("Media Info").font(.headline) }
            }

            Section {
                if session.subtitles.isEmpty {
                    Text("No subtitles available").foregroundColor(.secondary)
                } else {
                    ForEach(Array(session.subtitles.enumerated()), id: \.offset) { _, track in
                        SubtitleRow(track: track,
                                    isActive: track.name == session.activeSubtitle?.name) {
                            session.setSubtitleTrack(track)
                        }
                    }
                }
            } header: { Text("Subtitles").font(.headline) }

            Section {
                if let analysis = session.analysis {
                    Toggle(isOn: Binding(
                        get: { analysis.waveformEnabled },
                        set: { analysis.waveformEnabled = $0 }
                    )) { Text("Waveform") }
                    Toggle(isOn: Binding(
                        get: { analysis.vectorscopeEnabled },
                        set: { analysis.vectorscopeEnabled = $0 }
                    )) { Text("Vectorscope") }
                    Toggle(isOn: Binding(
                        get: { analysis.histogramEnabled },
                        set: { analysis.histogramEnabled = $0 }
                    )) { Text("Histogram") }
                    Toggle(isOn: Binding(
                        get: { analysis.audioMeteringEnabled },
                        set: { analysis.audioMeteringEnabled = $0 }
                    )) { Text("Audio Meters") }
                    if analysis.waveformEnabled {
                        WaveformView(waveform: analysis.waveform)
                    }
                    if analysis.vectorscopeEnabled {
                        VectorscopeView(vectorscope: analysis.vectorscope)
                    }
                    if analysis.histogramEnabled {
                        HistogramView(histogram: analysis.histogram)
                    }
                    if let sample = analysis.colorPicker {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Last Picked").font(.headline)
                            Text("#\(sample.hex8Bit)")
                            Text("R:\(sample.r8) G:\(sample.g8) B:\(sample.b8)")
                            Text(String(format: "H:%.0f°  S:%.2f  V:%.2f",
                                        sample.hue, sample.saturation, sample.value))
                        }
                        .font(.system(.caption, design: .monospaced))
                    }
                } else {
                    Text("GPU unavailable").foregroundColor(.secondary)
                }
            } header: { Text("Analyzers").font(.headline) }

            Spacer()
        }
        .padding()
        .frame(width: 220)
    }

    private func formatDuration(_ duration: CMTime) -> String {
        let s = CMTimeGetSeconds(duration)
        return String(format: "%d:%02d", Int(s)/60, Int(s)%60)
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).textSelection(.enabled)
        }
    }
}

struct SubtitleRow: View {
    let track: SubtitleTrack
    let isActive: Bool
    let onSelect: () -> Void
    var body: some View {
        HStack {
            Text(track.name)
            Spacer()
            if isActive { Image(systemName: "checkmark") }
        }
        .onTapGesture { onSelect() }
    }
}
