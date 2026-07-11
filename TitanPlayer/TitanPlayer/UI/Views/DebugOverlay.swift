import SwiftUI

struct DebugOverlay: View {
    @EnvironmentObject var session: PlaybackSession
    @State private var isVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isVisible {
                debugInfo
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleDebugOverlay)) { _ in
            isVisible.toggle()
        }
    }

    private var debugInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("PIXEL")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.yellow)
                Text(session.debugPixelFormat)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white)
            }
            HStack(spacing: 4) {
                Text("PIPE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.yellow)
                Text(session.debugPipelineState)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white)
            }
            HStack(spacing: 4) {
                Text("FRAMES")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.yellow)
                Text("\(session.debugPendingFrameCount)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white)
            }
            Divider()
                .background(Color.gray.opacity(0.5))
            DecoderHealthPanel()
        }
        .padding(6)
        .background(Color.black.opacity(0.7))
        .cornerRadius(4)
    }
}
