import SwiftUI

struct TelemetryPreferencesView: View {
    @EnvironmentObject var telemetry: TelemetryManager
    
    var body: some View {
        Form {
            Section {
                Toggle("Send anonymous crash reports", isOn: Binding(
                    get: { telemetry.isOptedIn },
                    set: { telemetry.setConsent($0) }
                ))
                
                Text("Crash reports include stack traces and device info. No personal data is collected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 400)
    }
}
