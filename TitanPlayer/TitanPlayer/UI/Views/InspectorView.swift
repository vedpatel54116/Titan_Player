import SwiftUI
import CoreMedia

struct InspectorView: View {
    @ObservedObject var viewModel: PlayerViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Media info section
            if let info = viewModel.mediaInfo {
                Section {
                    InfoRow(label: "Format", value: info.format)
                    InfoRow(label: "Duration", value: formatDuration(info.duration))
                    
                    ForEach(info.videoTracks.indices, id: \.self) { index in
                        let track = info.videoTracks[index]
                        InfoRow(label: "Video \(index + 1)", value: "\(track.codec) \(track.width)x\(track.height)")
                    }
                    
                    ForEach(info.audioTracks.indices, id: \.self) { index in
                        let track = info.audioTracks[index]
                        InfoRow(label: "Audio \(index + 1)", value: "\(track.codec) \(track.channels)ch")
                    }
                } header: {
                    Text("Media Info")
                        .font(.headline)
                }
            }
            
            // Subtitle section
            Section {
                if viewModel.subtitles.isEmpty {
                    Text("No subtitles available")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(Array(viewModel.subtitles.enumerated()), id: \.offset) { _, track in
                        SubtitleRow(track: track, isActive: track.name == viewModel.activeSubtitle?.name) {
                            viewModel.setSubtitleTrack(track)
                        }
                    }
                }
            } header: {
                Text("Subtitles")
                    .font(.headline)
            }
            
            Spacer()
        }
        .padding()
        .frame(width: 200)
    }
    
    private func formatDuration(_ duration: CMTime) -> String {
        let seconds = CMTimeGetSeconds(duration)
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Text(value)
                .textSelection(.enabled)
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
            
            if isActive {
                Image(systemName: "checkmark")
            }
        }
        .onTapGesture {
            onSelect()
        }
    }
}
