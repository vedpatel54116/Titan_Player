import SwiftUI

/// Compact audio meter readout. Used in the `ControlBar` and adjacent
/// HUD surfaces. Shows momentary / short-term / integrated LUFS plus
/// true-peak dBTP with a colored peak dot.
struct AudioMeterBar: View {
    let data: AudioMeteringData?

    var body: some View {
        HStack(spacing: 12) {
            peakDot
            VStack(alignment: .leading, spacing: 2) {
                Text(formatted("-23.4", "M", data?.momentaryLUFS))
                Text(formatted("-23.4", "S", data?.shortTermLUFS))
                Text(data?.integratedLUFS.map { String(format: "I: %.1f LUFS", $0) } ?? "I: —")
            }
            .font(.system(.caption, design: .monospaced))
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "Peak: %.2f dBTP", data?.truePeakDBTP ?? -120.0))
                Text(String(format: "Hold: %.2f dBTP", data?.peakHoldDBTP.value ?? -120.0))
            }
            .font(.system(.caption, design: .monospaced))
        }
        .padding(6)
        .background(Color.black.opacity(0.5))
        .cornerRadius(4)
    }

    private var peakDot: some View {
        let peak = data?.truePeakDBTP ?? -120.0
        let color: Color = peak > -1.0 ? .red : (peak > -6.0 ? .yellow : .green)
        return Circle().fill(color).frame(width: 12, height: 12)
    }

    private func formatted(_ placeholder: String, _ label: String, _ value: Float?) -> String {
        if let v = value {
            return String(format: "\(label): %.1f LUFS", v)
        } else {
            return "\(label): —"
        }
    }
}
