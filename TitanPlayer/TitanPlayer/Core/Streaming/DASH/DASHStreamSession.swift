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

        lock.withLock {
            self.demuxer = demuxer
            self._mediaInfo = info
        }

        return info
    }

    func nextPacket() async throws -> MediaPacket {
        let currentDemuxer: FFmpegDemuxer = try lock.withLock {
            guard let d = self.demuxer else {
                throw MediaError(code: .decodingFailed, message: "No active demuxer")
            }
            return d
        }

        return try await currentDemuxer.nextPacket()
    }

    func recordThroughput(bytesDownloaded: Int, durationSeconds: Double) {
        Task { @MainActor in
            abrController.recordThroughput(bytesDownloaded: bytesDownloaded, durationSeconds: durationSeconds)
            let newQuality = abrController.currentQuality
            let currentId = lock.withLock { self.currentQuality.id }
            if newQuality.id != currentId {
                try? await switchQuality(to: newQuality)
            }
        }
    }

    func switchQuality(to quality: DASHQuality) async throws {
        let url = try resolveSegmentURL(for: quality)
        let newDemuxer = FFmpegDemuxer()
        let info = try await newDemuxer.open(url: url)

        let oldDemuxer = lock.withLock { () -> FFmpegDemuxer? in
            let previous = self.demuxer
            self.demuxer = newDemuxer
            self._mediaInfo = info
            self.currentQuality = quality
            return previous
        }

        // Close the previous demuxer only after the new one is in place so
        // concurrent readers always observe a valid (non-nil) demuxer.
        oldDemuxer?.close()
    }

    func seek(to time: CMTime) async throws {
        let currentDemuxer: FFmpegDemuxer = try lock.withLock {
            guard let d = self.demuxer else {
                throw MediaError(code: .decodingFailed, message: "No active demuxer")
            }
            return d
        }

        try await currentDemuxer.seek(to: time)
    }

    func close() {
        let d = lock.withLock {
            let temp = self.demuxer
            self.demuxer = nil
            return temp
        }

        d?.close()
    }

    private func resolveSegmentURL(for quality: DASHQuality) throws -> URL {
        if let baseUrl = quality.baseUrl {
            if baseUrl.hasPrefix("http://") || baseUrl.hasPrefix("https://") {
                guard let resolved = URL(string: baseUrl) else {
                    throw StreamingError.invalidURL
                }
                return resolved
            }
            return manifestURL.deletingLastPathComponent().appendingPathComponent(baseUrl)
        }
        return manifestURL
    }
}

extension DASHStreamSession: MediaDemuxing {
    func open(url: URL) async throws -> MediaInfo {
        try await open()
    }
}
