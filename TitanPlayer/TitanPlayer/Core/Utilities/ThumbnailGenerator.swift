import Foundation
import AVFoundation
import CoreMedia
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import os

/// Generates SDR thumbnails from video files, with on-disk caching and HDR
/// tone-mapping for high-dynamic-range sources.
actor ThumbnailGenerator {
    private let logger = Logger(subsystem: "com.titanplayer", category: "ThumbnailGenerator")

    static let `default` = ThumbnailGenerator()

    private let defaultMaxSize = CGSize(width: 320, height: 180)

    private lazy var thumbnailsDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Thumbnails", isDirectory: true)
    }()

    private lazy var ciContext: CIContext = {
        CIContext(options: [
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            .useSoftwareRenderer: false
        ])
    }()

    /// Generates (or loads from cache) an SDR thumbnail for `url` at `time`.
    ///
    /// The result is cached to disk as a JPEG so subsequent requests for the
    /// same asset/time/size return instantly. HDR sources are tone-mapped to
    /// SDR before encoding.
    func generateThumbnail(
        for url: URL,
        at time: CMTime = .zero,
        maxSize: CGSize = CGSize(width: 320, height: 180)
    ) async throws -> CGImage {
        let cachePath = cachePath(for: url, at: time, maxSize: maxSize)
        if let cached = loadCachedImage(at: cachePath) {
            return cached
        }

        let bookmarkStore = await MainActor.run { BookmarkStore() }

        let cgImage = try await bookmarkStore.withSecurityScopedAccess(url: url) { scopedURL in
            try await self.extractImage(from: scopedURL, at: time, maxSize: maxSize)
        }

        let sdrImage = tonemapToSDRIfNeeded(cgImage)

        try? writeImage(sdrImage, to: cachePath)
        return sdrImage
    }

    /// Returns the on-disk path of a previously cached thumbnail for the default
    /// time (`.zero`) and default size (`320×180`), or `nil` if none exists yet.
    func cachedThumbnailPath(for url: URL) -> URL? {
        let path = cachePath(for: url, at: .zero, maxSize: defaultMaxSize)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    // MARK: - Extraction

    private func extractImage(from url: URL, at time: CMTime, maxSize: CGSize) async throws -> CGImage {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxSize
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, Error>) in
            generator.generateCGImageAsynchronously(for: time) { cgImage, _, error in
                if let cgImage {
                    continuation.resume(returning: cgImage)
                } else if let error {
                    continuation.resume(throwing: ThumbnailError.extractionFailed(error))
                } else {
                    continuation.resume(throwing: ThumbnailError.noImage)
                }
            }
        }
    }

    // MARK: - HDR tone mapping

    private func tonemapToSDRIfNeeded(_ cgImage: CGImage) -> CGImage {
        guard isHDR(cgImage.colorSpace) else { return cgImage }

        let ciImage = CIImage(cgImage: cgImage).oriented(forExifOrientation: 1)

        let toneMapped: CIImage
        if let filter = CIFilter(
            name: "CILinearToSRGBToneCurve",
            parameters: [kCIInputImageKey: ciImage]
        ), let filtered = filter.outputImage {
            toneMapped = filtered
        } else {
            toneMapped = ciImage
        }

        guard let output = ciContext.createCGImage(toneMapped, from: toneMapped.extent) else {
            return cgImage
        }
        return output
    }

    private func isHDR(_ colorSpace: CGColorSpace?) -> Bool {
        guard let cs = colorSpace, let name = cs.name else { return false }
        let hdrNames: [CFString] = [
            CGColorSpace.itur_2100_PQ,
            CGColorSpace.itur_2100_HLG,
            CGColorSpace.extendedLinearSRGB,
            CGColorSpace.extendedSRGB
        ]
        return hdrNames.contains(where: { name == $0 })
    }

    // MARK: - Caching

    private func cachePath(for url: URL, at time: CMTime, maxSize: CGSize) -> URL {
        let key = "\(url.path)|\(time.seconds)|\(Int(maxSize.width))x\(Int(maxSize.height))"
        let digest = SHA256.hash(data: Data(key.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return thumbnailsDirectory.appendingPathComponent("\(hash).jpg")
    }

    private func loadCachedImage(at path: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(path as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private func writeImage(_ cgImage: CGImage, to path: URL) throws {
        try FileManager.default.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ThumbnailError.cacheWriteFailed
        }

        let options: CFDictionary = [
            kCGImageDestinationLossyCompressionQuality: 0.85
        ] as CFDictionary

        CGImageDestinationAddImage(destination, cgImage, options)
        guard CGImageDestinationFinalize(destination) else {
            throw ThumbnailError.cacheWriteFailed
        }

        do {
            try data.write(to: path, options: .atomic)
        } catch {
            throw ThumbnailError.cacheWriteFailed
        }
    }

    // MARK: - Errors

    enum ThumbnailError: Error {
        case extractionFailed(Error)
        case noImage
        case cacheWriteFailed
    }
}
