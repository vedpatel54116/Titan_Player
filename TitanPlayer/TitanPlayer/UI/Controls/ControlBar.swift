import SwiftUI

struct ControlBar: View {
    @ObservedObject var viewModel: PlayerViewModel
    @State private var isEditingSeek = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Seek slider
            SeekSlider(
                value: Binding(
                    get: { viewModel.currentTime },
                    set: { newValue in
                        if !isEditingSeek {
                            Task { await viewModel.seek(to: newValue) }
                        }
                    }
                ),
                range: 0...max(viewModel.duration, 1),
                onEditingChanged: { editing in
                    isEditingSeek = editing
                }
            )
            .padding(.horizontal, 16)
            .padding(.top, 8)
            
            // Controls
            HStack(spacing: 24) {
                // Playback controls
                HStack(spacing: 16) {
                    Button(action: { Task { await viewModel.seekBackward() } }) {
                        Image(systemName: "gobackward.10")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: { viewModel.togglePlayPause() }) {
                        Image(systemName: viewModel.playState == .playing ? "pause.fill" : "play.fill")
                            .font(.title)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: { Task { await viewModel.seekForward() } }) {
                        Image(systemName: "goforward.10")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                }
                
                // Time display
                Text("\(formatTime(viewModel.currentTime)) / \(formatTime(viewModel.duration))")
                    .font(.caption)
                    .monospacedDigit()
                
                Spacer()
                
                // Volume controls
                HStack(spacing: 8) {
                    Button(action: { viewModel.toggleMute() }) {
                        Image(systemName: volumeIcon)
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    
                    Slider(value: Binding(
                        get: { viewModel.volume },
                        set: { viewModel.setVolume($0) }
                    ), in: 0...1)
                    .frame(width: 100)
                }
                
                // Subtitle button
                Menu {
                    ForEach(viewModel.subtitles, id: \.name) { track in
                        Button(track.name) {
                            viewModel.setSubtitleTrack(track)
                        }
                    }
                    
                    Divider()
                    
                    Button("Load External Subtitle...") {
                        // Open file picker
                    }
                } label: {
                    Image(systemName: "captions.bubble")
                        .font(.title3)
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
    }
    
    private var volumeIcon: String {
        if viewModel.isMuted {
            return "speaker.slash.fill"
        } else if viewModel.volume < 0.33 {
            return "speaker.wave.1.fill"
        } else if viewModel.volume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
