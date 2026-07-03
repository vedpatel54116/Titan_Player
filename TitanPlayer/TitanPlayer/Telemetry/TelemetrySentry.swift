import Sentry

protocol SentrySDKProtocol: Sendable {
    func start(dsn: String, tracesSampleRate: NSNumber)
    func capture(event: Event)
    func close()
}

struct LiveSentrySDK: SentrySDKProtocol {
    func start(dsn: String, tracesSampleRate: NSNumber) {
        SentrySDK.start { options in
            options.dsn = dsn
            options.tracesSampleRate = tracesSampleRate
            options.enableAutoSessionTracking = true
            options.attachStacktrace = true
            options.sendDefaultPii = false
        }
    }

    func capture(event: Event) {
        SentrySDK.capture(event: event)
    }

    func close() {
        SentrySDK.close()
    }
}
