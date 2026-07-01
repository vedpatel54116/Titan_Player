import Foundation
import CoreGraphics

protocol AdaptiveSubsystemAdapting: AnyObject {
    @MainActor func apply(_ actions: [QualityAction], context: PerformanceContext)
}

@MainActor
final class DecoderAdapter: AdaptiveSubsystemAdapting {
    private weak var target: AdaptiveDecoderManager?

    init(target: AdaptiveDecoderManager) {
        self.target = target
    }

    func apply(_ actions: [QualityAction], context: PerformanceContext) {
        guard let target else { return }
        for action in actions {
            if case .preferHardware(let want) = action {
                target.forcePreference(want ? .preferHardware : .preferSoftware)
            }
        }
    }
}

@MainActor
final class RenderAdapter: AdaptiveSubsystemAdapting {
    weak var target: AnyObject?
    private let setter: (ResolutionCap) -> Void

    init(target: AnyObject, setter: @escaping (ResolutionCap) -> Void) {
        self.target = target
        self.setter = setter
    }

    convenience init(target: MetalRenderer) {
        self.init(target: target) { cap in target.setResolutionCap(cap) }
    }

    func apply(_ actions: [QualityAction], context: PerformanceContext) {
        for action in actions {
            if case .downscaleRenderTo(let cap) = action {
                setter(cap)
            }
        }
    }
}

@MainActor
final class StreamingAdapter: AdaptiveSubsystemAdapting {
    private weak var target: StreamingManager?

    init(target: StreamingManager) {
        self.target = target
    }

    func apply(_ actions: [QualityAction], context: PerformanceContext) {
        guard let target else { return }
        for action in actions {
            if case .streamPreferBitrate(let bitrate) = action {
                target.setPreferredPeakBitrate(bitrate)
            }
        }
    }
}

@MainActor
final class AudioAdapter: AdaptiveSubsystemAdapting {
    weak var target: AnyObject?
    private let setter: (AudioMode) -> Void

    init(target: AnyObject, setter: @escaping (AudioMode) -> Void) {
        self.target = target
        self.setter = setter
    }

    convenience init(target: AudioEngine) {
        self.init(target: target) { mode in target.setComplexityMode(mode) }
    }

    func apply(_ actions: [QualityAction], context: PerformanceContext) {
        for action in actions {
            if case .reduceAudioComplexity(let mode) = action {
                setter(mode)
            }
        }
    }
}
