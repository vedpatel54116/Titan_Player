import Foundation
import CoreVideo
import CoreMedia
import os.log

final class PixelBufferPool {
    static let shared = PixelBufferPool()
    
    private let logger = Logger(subsystem: "com.titanplayer", category: "PixelBufferPool")
    private var pool: CVPixelBufferPool?
    private var poolAttributes: (width: Int, height: Int, pixelFormat: OSType)?
    private let lock = NSLock()
    
    private init() {}
    
    func ensurePool(width: Int, height: Int, pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) -> CVPixelBufferPool {
        lock.lock()
        defer { lock.unlock() }
        
        if let existing = pool, let attrs = poolAttributes, attrs.width == width, attrs.height == height, attrs.pixelFormat == pixelFormat {
            return existing
        }
        
        let pixelBufferAttrs: NSDictionary = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        
        let poolAttrs: NSDictionary = [
            kCVPixelBufferPoolMinimumBufferCountKey: 12
        ]
        
        var newPool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttrs as CFDictionary,
            pixelBufferAttrs as CFDictionary,
            &newPool
        )
        
        guard status == kCVReturnSuccess, let createdPool = newPool else {
            logger.error("Failed to create pixel buffer pool: \(status)")
            return createFallbackPool(width: width, height: height)
        }
        
        pool = createdPool
        poolAttributes = (width, height, pixelFormat)
        logger.info("Created pixel buffer pool: \(width)x\(height) fmt=\(pixelFormat)")
        
        return createdPool
    }
    
    func allocateBuffer() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        
        guard let pool = pool else { return nil }
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        
        if status != kCVReturnSuccess {
            logger.warning("Pool exhausted, attempting recovery: \(status)")
            CVPixelBufferPoolFlush(pool, CVPixelBufferPoolFlushFlags(rawValue: 0))
            
            let retryStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
            if retryStatus != kCVReturnSuccess {
                logger.error("Recovery failed: \(retryStatus)")
                return nil
            }
        }
        
        return pixelBuffer
    }
    
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        pool = nil
        poolAttributes = nil
    }
    
    private func createFallbackPool(width: Int, height: Int) -> CVPixelBufferPool {
        let attrs: NSDictionary = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        
        var newPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &newPool)
        
        if let createdPool = newPool {
            return createdPool
        }
        
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &pixelBuffer)
        
        var fallbackPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &fallbackPool)
        
        return fallbackPool ?? (pixelBuffer as AnyObject as! CVPixelBufferPool)
    }
}
