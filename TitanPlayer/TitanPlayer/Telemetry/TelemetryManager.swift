import Foundation
import SwiftUI
import Sentry

@MainActor
final class TelemetryManager: ObservableObject, TelemetryProviding {
    static let shared = TelemetryManager()
    
    @AppStorage("titanplayer.telemetry.consented") private var consented = false
    @AppStorage("titanplayer.telemetry.hasPrompted") private var hasPrompted = false
    
    private let dsn: String
    
    var isOptedIn: Bool { consented }
    var needsConsentPrompt: Bool { !hasPrompted }
    
    private init() {
        self.dsn = Bundle.main.infoDictionary?["SentryDSN"] as? String ?? ""
    }
    
    func initialize() {
        guard consented, !dsn.isEmpty else { return }
        SentrySDK.start { options in
            options.dsn = self.dsn
            options.tracesSampleRate = 0.2
            options.enableAutoSessionTracking = true
            options.attachStacktrace = true
            options.sendDefaultPii = false
        }
    }
    
    func record(_ event: TelemetryEvent) {
        guard consented else { return }
        
        let sentryEvent = Event(level: .info)
        
        switch event {
        case .playbackFailed(let codec, let resolution, let errorCode, let source):
            sentryEvent.message = SentryMessage(formatted: "playback_failed")
            sentryEvent.tags = [
                "codec": codec,
                "resolution": resolution,
                "error_code": errorCode,
                "source": source.rawValue
            ]
            sentryEvent.level = .error
            
        case .hdrModeUsed(let mode, let duration):
            sentryEvent.message = SentryMessage(formatted: "hdr_mode_used")
            sentryEvent.tags = [
                "hdr_mode": mode.rawValue
            ]
            sentryEvent.extra = ["duration_seconds": duration]
            
        case .performanceSnapshot(let cpu, let gpu, let resolution, let codec):
            sentryEvent.message = SentryMessage(formatted: "performance_snapshot")
            sentryEvent.tags = [
                "resolution": resolution,
                "codec": codec
            ]
            sentryEvent.extra = [
                "cpu_percent": cpu,
                "gpu_percent": gpu
            ]
            
        case .audioFormatUsed(let format, let sampleRate, let bitDepth):
            sentryEvent.message = SentryMessage(formatted: "audio_format_used")
            sentryEvent.tags = [
                "audio_format": format.rawValue,
                "sample_rate": "\(sampleRate)",
                "bit_depth": "\(bitDepth)"
            ]

        case .compatibilityModeActivated(let reason, let source):
            sentryEvent.message = SentryMessage(formatted: "compatibility_mode_activated")
            sentryEvent.tags = [
                "reason": reason,
                "source": source.rawValue
            ]
            sentryEvent.level = .warning
        }
        
        SentrySDK.capture(event: sentryEvent)
    }
    
    func setConsent(_ granted: Bool) {
        consented = granted
        hasPrompted = true
        if granted {
            initialize()
        } else {
            SentrySDK.close()
        }
    }
}
