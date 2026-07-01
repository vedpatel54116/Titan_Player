import SwiftUI

struct AudioOnlyView: View {
    @EnvironmentObject var session: PlaybackSession
    var compact: Bool = false

    var body: some View {
        VStack(spacing: compact ? 8 : 24) {
            Image(systemName: "music.note")
                .font(.system(size: compact ? 40 : 96))
                .foregroundColor(.secondary)

            VStack(spacing: compact ? 2 : 8) {
                Text(session.mediaInfo?.format.uppercased() ?? "Now Playing")
                    .font(compact ? .caption : .title2)
                    .foregroundColor(.primary)
                if !compact {
                    Text(formatTime(session.currentTime))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
            }

            if !compact {
                Button(action: { session.togglePlayPause() }) {
                    Image(systemName: session.playState == .playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
