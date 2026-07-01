import SwiftUI

struct DisplaySelectorView: View {
    let displays: [ExternalDisplayConfig]
    @Binding var primaryDisplayID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Primary Display")
                .font(.headline)

            ForEach(displays) { display in
                Button {
                    primaryDisplayID = display.stableID
                } label: {
                    HStack {
                        Circle()
                            .fill(display.stableID == primaryDisplayID ? Color.accentColor : Color.gray.opacity(0.3))
                            .frame(width: 12, height: 12)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(display.displayName)
                                .font(.body)
                                .foregroundColor(.primary)

                            HStack(spacing: 6) {
                                if display.hdrSupported {
                                    Text("HDR")
                                        .font(.caption2)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.orange.opacity(0.2))
                                        .cornerRadius(3)
                                }

                                if display.maxEDRLuminance > 0 {
                                    Text("\(Int(display.maxEDRLuminance)) nits")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        Spacer()

                        if display.stableID == primaryDisplayID {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .frame(minWidth: 200)
    }
}
