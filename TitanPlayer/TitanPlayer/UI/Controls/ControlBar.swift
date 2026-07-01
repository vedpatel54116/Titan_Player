import SwiftUI

struct ControlBar: View {
    @EnvironmentObject var session: PlaybackSession
    @State private var isEditingSeek = false
    @State private var showSubtitleStyling = false

    var body: some View {
        VStack(spacing: 0) {
            if session.isMediaLoaded {
                SeekSlider(
                    value: Binding(
                        get: { session.currentTime },
                        set: { newValue in
                            if !isEditingSeek {
                                Task { await session.seek(to: newValue) }
                            }
                        }
                    ),
                    range: 0...max(session.duration, 1),
                    onEditingChanged: { editing in isEditingSeek = editing }
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            HStack(spacing: 24) {
                if !session.isMediaLoaded {
                    Spacer()
                    Text("Open a file to begin")
                        .foregroundColor(.secondary)
                    Spacer()
                } else {
                    transportCluster
                    Text("\(formatTime(session.currentTime)) / \(formatTime(session.duration))")
                        .font(.caption)
                        .monospacedDigit()
                    Spacer()
                    volumeCluster
                    routeCluster
                    if session.analysis.audioMeteringEnabled {
                        AudioMeterBar(data: session.analysis.audioMeter.metering)
                    }
                    if session.isHDRContent { hdrCluster }
                    if !session.subtitles.isEmpty { subtitleCluster }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
        .accessibilityIdentifier("controlBar.root")
    }

    private var transportCluster: some View {
        HStack(spacing: 16) {
            Button(action: { Task { await session.seekBackward() } }) {
                Image(systemName: "gobackward.10").font(.title2)
            }
            .buttonStyle(.plain)

            Button(action: { session.togglePlayPause() }) {
                Image(systemName: session.playState == .playing ? "pause.fill" : "play.fill")
                    .font(.title)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("controlBar.playPause")

            Button(action: { Task { await session.seekForward() } }) {
                Image(systemName: "goforward.10").font(.title2)
            }
            .buttonStyle(.plain)
        }
    }

    private var volumeCluster: some View {
        HStack(spacing: 8) {
            Button(action: { session.toggleMute() }) {
                Image(systemName: volumeIcon).font(.title3)
            }
            .buttonStyle(.plain)
            Slider(value: Binding(
                get: { session.volume },
                set: { session.setVolume($0) }
            ), in: 0...1)
            .frame(width: 100)
        }
    }

    private var routeCluster: some View {
        DisplayRoutePickerView()
            .frame(width: 28, height: 22)
            .help("Send video & audio to an AirPlay receiver or external display")
            .accessibilityIdentifier("airPlay.root")
    }

    private var hdrCluster: some View {
        HStack(spacing: 8) {
            Label("HDR", systemImage: "sparkles")
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.yellow.opacity(0.2))
                .clipShape(Capsule())
                .accessibilityIdentifier("controlBar.hdrBadge")
            Toggle("", isOn: $session.toneMappingEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
            Slider(value: $session.brightness, in: 0...1)
                .frame(width: 80)
        }
    }

    private var subtitleCluster: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(session.subtitles, id: \.name) { track in
                    Button(track.name) { session.setSubtitleTrack(track) }
                }
                Divider()
                Button("Load External Subtitle…") {}
            } label: {
                Image(systemName: "captions.bubble").font(.title3)
            }
            .menuStyle(.borderlessButton)

            Button(action: { showSubtitleStyling.toggle() }) {
                Image(systemName: "textformat")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSubtitleStyling) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Subtitle Styling").font(.headline)
                    HStack {
                        Text("Size")
                        Stepper(value: $session.subtitleFontSize, in: 0.5...3, step: 0.1) {
                            Text(String(format: "%.1f×", session.subtitleFontSize))
                        }
                    }
                    HStack {
                        Text("Position")
                        Picker("", selection: Binding(
                            get: {
                                if case .top = session.subtitlePosition { return true }
                                return false
                            },
                            set: { isTop in session.subtitlePosition = isTop ? .top : .bottom }
                        )) {
                            Text("Bottom").tag(false)
                            Text("Top").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                    HStack {
                        Text("Background")
                        Slider(value: $session.subtitleBackgroundOpacity, in: 0...1)
                    }
                }
                .padding()
                .frame(width: 240)
            }
        }
    }

    private var volumeIcon: String {
        if session.isMuted { return "speaker.slash.fill" }
        if session.volume < 0.33 { return "speaker.wave.1.fill" }
        if session.volume < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private func formatTime(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds)/60, Int(seconds)%60)
    }
}
