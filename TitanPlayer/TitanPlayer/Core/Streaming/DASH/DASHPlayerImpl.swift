import AVFoundation

@MainActor
final class DASHPlayerImpl: DASHPlayer {
    private var abrController: DASHABRController?
    private var currentSession: DASHStreamSession?

    func playableAsset(for url: URL) async throws -> AVURLAsset {
        throw StreamingError.dashNotSupported(url)
    }

    func streamSession(for url: URL) async throws -> DASHStreamSession {
        let manifest = try await MPDParser.parse(url: url)
        let qualities = manifest.allVideoQualities
        guard let lowest = manifest.lowestVideoQuality, !qualities.isEmpty else {
            throw StreamingError.dashNotSupported(url)
        }

        let controller = try DASHABRController(qualities: qualities, initial: lowest)
        self.abrController = controller

        let session = DASHStreamSession(
            manifest: manifest,
            manifestURL: url,
            abrController: controller,
            initialQuality: lowest
        )
        _ = try await session.open()

        self.currentSession = session
        return session
    }

    var currentVariants: [StreamingQuality] {
        get async {
            abrController?.availableQualities.map { q in
                .variant(
                    resolution: CGSize(width: q.width ?? 0, height: q.height ?? 0),
                    bitrate: q.bandwidth,
                    codec: q.codec
                )
            } ?? []
        }
    }
}
