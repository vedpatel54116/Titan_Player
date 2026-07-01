import os.log

enum LogLevel: Int {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
}

final class AudioDiagnostics {
    var logLevel: LogLevel = .info
    private let logger = Logger(subsystem: "com.titanplayer.audio", category: "Diagnostics")

    func log(_ message: String, level: LogLevel = .info) {
        guard level.rawValue >= logLevel.rawValue else { return }

        switch level {
        case .debug:
            logger.debug("\(message, privacy: .public)")
        case .info:
            logger.info("\(message, privacy: .public)")
        case .warning:
            logger.warning("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }
    }

    func logFormatDetection(_ format: AudioFormatType) {
        log("Detected format: \(format)", level: .info)
    }

    func logHeadTrackingStatus(_ isTracking: Bool) {
        log("Head tracking: \(isTracking ? "active" : "inactive")", level: .info)
    }

    func logPerformanceMetrics(_ metrics: AudioMetrics) {
        log("Latency: \(metrics.latency)s, CPU: \(metrics.cpuUsage * 100)%", level: .debug)
    }
}
