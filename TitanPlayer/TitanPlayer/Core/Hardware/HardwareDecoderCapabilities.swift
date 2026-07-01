import Foundation

/// Hardware capabilities for a Mac model tier, derived from
/// `MacModelIdentifier.detect()`. Distinct from the protocol-side
/// `DecoderCapabilities` (decoder output + codec gating).
struct HardwareCodecProfile: Sendable, Equatable {
    let hasHWH264: Bool
    let hasHWHEVC: Bool
    let hasProRes: Bool
    let hasProResRAW: Bool
    let hasAV1: Bool
    let hasDolbyVisionP5: Bool
    let hasDolbyVisionP8: Bool
    let hasHDR10: Bool
    let hasHLG: Bool

    static let intelBaseline = HardwareCodecProfile(
        hasHWH264: true,
        hasHWHEVC: false,
        hasProRes: false,
        hasProResRAW: false,
        hasAV1: false,
        hasDolbyVisionP5: false,
        hasDolbyVisionP8: false,
        hasHDR10: false,
        hasHLG: false
    )

    static let appleM1 = HardwareCodecProfile(
        hasHWH264: true,
        hasHWHEVC: true,
        hasProRes: true,
        hasProResRAW: false,
        hasAV1: false,
        hasDolbyVisionP5: false,
        hasDolbyVisionP8: false,
        hasHDR10: true,
        hasHLG: true
    )

    static let appleM2 = HardwareCodecProfile(
        hasHWH264: true,
        hasHWHEVC: true,
        hasProRes: true,
        hasProResRAW: true,
        hasAV1: false,
        hasDolbyVisionP5: false,
        hasDolbyVisionP8: false,
        hasHDR10: true,
        hasHLG: true
    )

    static let appleM3 = HardwareCodecProfile(
        hasHWH264: true,
        hasHWHEVC: true,
        hasProRes: true,
        hasProResRAW: true,
        hasAV1: true,
        hasDolbyVisionP5: true,
        hasDolbyVisionP8: false,
        hasHDR10: true,
        hasHLG: true
    )

    static let appleM4 = HardwareCodecProfile(
        hasHWH264: true,
        hasHWHEVC: true,
        hasProRes: true,
        hasProResRAW: true,
        hasAV1: true,
        hasDolbyVisionP5: true,
        hasDolbyVisionP8: true,
        hasHDR10: true,
        hasHLG: true
    )

    static func detect() -> HardwareCodecProfile {
        let id = MacModelIdentifier.detect()
        switch id {
        case .intelUnknown, .macBookProIntel2018Baseline:
            return .intelBaseline
        case .macMiniM1, .macBookProM1Pro, .macBookProM1Max,
             .iMacM1, .macStudioM1Ultra:
            return .appleM1
        case .macBookProM2Pro, .macBookProM2Max,
             .macMiniM2, .macStudioM2Ultra, .macProM2Ultra:
            return .appleM2
        case .macBookProM3Pro:
            return .appleM3
        case .macBookProM4Pro, .macMiniM4:
            return .appleM4
        }
    }
}
