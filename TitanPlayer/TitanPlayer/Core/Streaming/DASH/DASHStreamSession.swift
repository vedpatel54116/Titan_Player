import Foundation
import CoreMedia
import Libavformat

final class DASHStreamSession: @unchecked Sendable {
    let manifest: MPDManifest
    let manifestURL: URL
    private let abrController: DASHABRController
    private var currentQuality: DASHQuality
    private var demuxer: FFmpegDemuxer?
    private let lock = NSLock()

    private var _mediaInfo: MediaInfo?
    var mediaInfo: MediaInfo? { lock.lock(); defer { lock.unlock() }; return _mediaInfo }

    init(manifest: MPDManifest, manifestURL: URL, abrController: DASHABRController, initialQuality: DASHQuality) {
        self.manifest = manifest
        self.manifestURL = manifestURL
        self.abrController = abrController
        self.currentQuality = initialQuality
    }

    func open() async throws -> MediaInfo {
        let quality = currentQuality
        let url = try resolveSegmentURL(for: quality)

        let demuxer = FFmpegDemuxer()
        let info = try await demuxer.open(url: url)

        lock.lock()
        self.demuxer = demuxer
        self._mediaInfo = info
        lock.unlock()

        return info
    }

    func nextPacket() async throws -> MediaPacket {
        let currentDemuxer: FFmpegDemuxer
        lock.lock()
        guard let d = self.demuxer else {
            lock.unlock()
            throw MediaError(code: .decodingFailed, message: "No active demuxer")
        }
        currentDemuxer = d
        lock.unlock()

        return try await currentDemuxer.nextPacket()
    }

    func recordThroughput(bytesDownloaded: Int, durationSeconds: Double) {
        Task { @MainActor in
            abrController.recordThroughput(bytesDownloaded: bytesDownloaded, durationSeconds: durationSeconds)
            let newQuality = abrController.currentQuality
            if newQuality.id != currentQuality.id {
                try? await switchQuality(to: newQuality)
            }
        }
    }

    func switchQuality(to quality: DASHQuality) async throws {
        lock.lock()
        let oldDemuxer = self.demuxer
        lock.unlock()

        oldDemuxer?.close()

        let url = try resolveSegmentURL(for: quality)
        let newDemuxer = FFmpegDemuxer()
        let info = try await newDemuxer.open(url: url)

        lock.lock()
        self.demuxer = newDemuxer
        self._mediaInfo = info
        self.currentQuality = quality
        lock.unlock()
    }

    func seek(to time: CMTime) async throws {
        let currentDemuxer: FFmpegDemuxer
        lock.lock()
        guard let d = self.demuxer else {
            lock.unlock()
            throw MediaError(code: .decodingFailed, message: "No active demuxer")
        }
        currentDemuxer = d
        lock.unlock()

        try await currentDemuxer.seek(to: time)
    }

    func close() {
        lock.lock()
        let d = self.demuxer
        self.demuxer = nil
        lock.unlock()

        d?.close()
    }

    private func resolveSegmentURL(for quality: DASHQuality) throws -> URL {
        return manifestURL
    }
}

extension DASHStreamSession: MediaDemuxing {
    func open(url: URL) async throws -> MediaInfo {
        try await open()
    }
}
