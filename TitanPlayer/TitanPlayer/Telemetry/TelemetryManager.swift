import Foundation
import SwiftUI
import Sentry

@MainActor
final class TelemetryManager: ObservableObject, TelemetryProviding {
    static let shared = TelemetryManager()
    
    @AppStorage("titanplayer.telemetry.consented") private var consented = false
    @AppStorage("titanplayer.telemetry.hasPrompted") private var hasPrompted = false
    
    private let dsn: String
    private let sentry: SentrySDKProtocol
    
    var isOptedIn: Bool { consented }
    var needsConsentPrompt: Bool { !hasPrompted }
    
    init(
        dsn: String = Bundle.main.infoDictionary?["SentryDSN"] as? String ?? "",
        sentry: SentrySDKProtocol = LiveSentrySDK()
    ) {
        self.dsn = dsn
        self.sentry = sentry
    }
    
    func initialize() {
        guard consented, !dsn.isEmpty else { return }
        sentry.start(dsn: dsn, tracesSampleRate: NSNumber(value: 0.2))
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
        
        sentry.capture(event: sentryEvent)
    }
    
    func setConsent(_ granted: Bool) {
        consented = granted
        hasPrompted = true
        if granted {
            initialize()
        } else {
            sentry.close()
        }
    }
}
