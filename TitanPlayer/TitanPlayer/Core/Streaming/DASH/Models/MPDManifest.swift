import Foundation

struct MPDManifest: Sendable {
    let type: MPDType
    let mediaPresentationDuration: Double?
    let minBufferTime: Double?
    let videoAdaptations: [AdaptationSet]
    let audioAdaptations: [AdaptationSet]

    enum MPDType: String, Sendable {
        case `static`
        case dynamic
    }

    struct AdaptationSet: Sendable {
        let id: String?
        let mimeType: String
        let lang: String?
        let representations: [DASHQuality]
    }
}

extension MPDManifest {
    var allVideoQualities: [DASHQuality] {
        videoAdaptations.flatMap(\.representations)
    }

    var allAudioQualities: [DASHQuality] {
        audioAdaptations.flatMap(\.representations)
    }

    var lowestVideoQuality: DASHQuality? {
        DASHQuality.sortedByBandwidth(allVideoQualities).first
    }
}
