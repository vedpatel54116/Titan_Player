import SwiftUI

/// Compact panel surfacing the live decoder pipeline state. Shown as part of
/// the debug overlay (Cmd+Shift+D).
struct DecoderHealthPanel: View {
    @EnvironmentObject var session: PlaybackSession

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row(label: "DECODER", value: session.decoderHealth.activeDecoder, color: .green)
            row(label: "FALLBACK", value: "\(session.decoderHealth.fallbackCount)", color: .orange)
            row(
                label: "LASTERR",
                value: session.decoderHealth.lastErrorCode.map { "\($0)" } ?? "none",
                color: session.decoderHealth.lastErrorCode == nil ? .secondary : .red
            )
            row(label: "PIXEL", value: session.decoderHealth.pixelFormatDescription, color: .yellow)
        }
        .padding(6)
        .background(Color.black.opacity(0.7))
        .cornerRadius(4)
    }

    private func row(label: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.yellow)
            Text(value)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white)
        }
    }
}
