import SwiftUI

struct PrivacyConsentDialog: View {
    @EnvironmentObject var telemetry: TelemetryManager
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            
            Text("Help Improve TitanPlayer")
                .font(.title2)
            
            Text("""
                TitanPlayer can automatically send anonymous crash reports \
                and usage statistics to help us fix bugs and improve performance. \
                No personal data is collected.
                """)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            
            VStack(alignment: .leading, spacing: 8) {
                Label("Crash reports (stack traces only)", systemImage: "ladybug")
                Label("Playback error types and frequencies", systemImage: "exclamationmark.triangle")
                Label("HDR and audio format usage", systemImage: "waveform")
                Label("Anonymous performance metrics", systemImage: "gauge")
            }
            .font(.callout)
            
            HStack(spacing: 16) {
                Button("Don't Send") { respond(false) }
                    .keyboardShortcut(.cancelAction)
                
                Button("Allow") { respond(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(40)
        .frame(width: 480)
    }
    
    private func respond(_ consented: Bool) {
        telemetry.setConsent(consented)
    }
}
