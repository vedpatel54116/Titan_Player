import SwiftUI

struct MiniControlBar: View {
    @EnvironmentObject var session: PlaybackSession

    var body: some View {
        HStack(spacing: 12) {
            Button(action: { Task { await session.seekBackward() } }) {
                Image(systemName: "gobackward.10")
                    .font(.body)
            }
            .buttonStyle(.plain)
            .disabled(!session.isMediaLoaded)

            Button(action: { session.togglePlayPause() }) {
                Image(systemName: session.playState == .playing ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(!session.isMediaLoaded)

            Button(action: { Task { await session.seekForward() } }) {
                Image(systemName: "goforward.10")
                    .font(.body)
            }
            .buttonStyle(.plain)
            .disabled(!session.isMediaLoaded)

            Spacer()

            Text("\(formatTime(session.currentTime)) / \(formatTime(session.duration))")
                .font(.caption2)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
