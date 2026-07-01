import Foundation

@MainActor
protocol TelemetryProviding: AnyObject {
    var isOptedIn: Bool { get }
    var needsConsentPrompt: Bool { get }
    func initialize()
    func record(_ event: TelemetryEvent)
    func setConsent(_ granted: Bool)
}
