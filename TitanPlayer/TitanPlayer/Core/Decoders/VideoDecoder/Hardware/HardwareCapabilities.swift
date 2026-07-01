import Foundation
import VideoToolbox

// MARK: - Hardware Capabilities

struct HardwareCapabilities: Sendable {
    let supportedCodecs: Set<VideoCodec>
    let maxResolution: CGSize
    let supportsHDR: Bool
    let supportsHardwareAcceleration: Bool

    // MARK: - Query System Capabilities

    static func query() -> HardwareCapabilities {
        var supportedCodecs: Set<VideoCodec> = [.h264, .hevc]
        var maxResolution = CGSize(width: 4096, height: 2160)
        let supportsHDR = true

        // VP9 hardware decoding on Apple Silicon (M1+).
        if isAppleSilicon() {
            supportedCodecs.insert(.vp9)
            maxResolution = CGSize(width: 8192, height: 4320)
        }

        // AV1 hardware decoding on Apple Silicon M3+.
        if isM3OrLater() {
            supportedCodecs.insert(.av1)
            maxResolution = CGSize(width: 8192, height: 4320)
        }

        return HardwareCapabilities(
            supportedCodecs: supportedCodecs,
            maxResolution: maxResolution,
            supportsHDR: supportsHDR,
            supportsHardwareAcceleration: true
        )
    }

    // MARK: - Codec Support Check

    static func isCodecSupported(_ codec: VideoCodec) -> Bool {
        switch codec {
        case .h264, .hevc:
            // VideoToolbox hardware decode for H.264/HEVC is available on
            // all supported Macs (Intel + Apple Silicon).
            return true
        case .vp9:
            // VP9 hardware decode is Apple Silicon only (M1+).
            return isAppleSilicon()
        case .av1:
            // AV1 hardware decode requires M3+.
            return isM3OrLater()
        case .mpeg2, .vc1:
            // No VideoToolbox hardware decode; handled in software via FFmpeg.
            return false
        }
    }

    // MARK: - Max Resolution for Codec

    static func maxResolution(for codec: VideoCodec) -> CGSize {
        switch codec {
        case .h264:
            return CGSize(width: 4096, height: 2160)
        case .hevc:
            return CGSize(width: 8192, height: 4320)
        case .vp9:
            return CGSize(width: 8192, height: 4320)
        case .av1:
            return CGSize(width: 8192, height: 4320)
        case .mpeg2:
            return CGSize(width: 1920, height: 1080)
        case .vc1:
            return CGSize(width: 1920, height: 1080)
        }
    }

    // MARK: - Hardware Detection

    /// True on Apple Silicon (arm64).
    static func isAppleSilicon() -> Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// Detects Apple Silicon M3 or later by parsing the `hw.perflevel1.physicalcpu`
    /// / machine model. AV1 hardware decode media engines are present from M3 on.
    static func isM3OrLater() -> Bool {
        guard isAppleSilicon() else { return false }
        return chipFamilyGeneration() >= 3
    }

    /// Returns the Apple Silicon generation (1 = M1, 2 = M2, 3 = M3, …).
    /// Derived from the `hw.optional.arm.FEAT_*` sysctl / chip model string.
    private static func chipFamilyGeneration() -> Int {
        let model = machineModel().lowercased()

        // Match "m1"/"m2"/"m3"/"m4" and their Pro/Max/Ultra variants.
        if model.contains("m4") { return 4 }
        if model.contains("m3") { return 3 }
        if model.contains("m2") { return 2 }
        if model.contains("m1") { return 1 }

        // Fallback: on arm64 with no recognizable model string, assume M1
        // (the baseline Apple Silicon generation) — conservative for AV1.
        #if arch(arm64)
        return 1
        #else
        return 0
        #endif
    }

    /// Reads the CPU brand string via `sysctlbyname("machdep.cpu.brand_string")`,
    /// e.g. "Apple M3 Pro" or "Apple M1 Max".
    private static func machineModel() -> String {
        var size: Int = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return ""
        }

        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: size)
        defer { buffer.deallocate() }

        guard sysctlbyname("machdep.cpu.brand_string", buffer, &size, nil, 0) == 0 else {
            return ""
        }

        return String(cString: buffer)
    }
}
