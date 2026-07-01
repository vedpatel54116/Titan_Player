import Foundation
import Combine
import AVFoundation
import CoreGraphics

struct StreamingVariantSnapshot: Equatable {
    let resolution: CGSize
    let bitrate: Int
    let codec: String?
}

protocol VariantProviding {
    var currentVariants: [StreamingVariantSnapshot] { get }
    var selectedVariant: StreamingVariantSnapshot? { get }
}

@MainActor
final class HLSVariantObserver: ObservableObject {
    @Published private(set) var current: StreamingQuality = .auto
    @Published private(set) var available: [StreamingQuality] = []

    private(set) var provider: (any VariantProviding)?
    private var pollingTask: Task<Void, Never>?

    func attach(provider: any VariantProviding) {
        self.provider = provider
        pollingTask?.cancel()
        refresh()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func detach() {
        pollingTask?.cancel()
        pollingTask = nil
        provider = nil
        current = .auto
        available = []
    }

    private func refresh() {
        guard let provider else { return }
        let variants = provider.currentVariants
        let availableNow = variants.map { snapshot in
            StreamingQuality.variant(
                resolution: snapshot.resolution,
                bitrate: snapshot.bitrate,
                codec: snapshot.codec
            )
        }
        if availableNow != available {
            available = availableNow
        }
        if let selected = provider.selectedVariant,
           let match = availableNow.first(where: {
               if case .variant(let res, let br, let codec) = $0 {
                   return res == selected.resolution
                       && br == selected.bitrate
                       && codec == selected.codec
               }
               return false
           }) {
            if match != current { current = match }
        } else if current != .auto {
            current = .auto
        }
    }
}

/// Production-only adapter that wraps an `AVPlayerItem`.
///
/// Both `AVPlayerItem.variants` and `AVPlayerItem.currentVariant` are
/// macOS 15+ APIs. On macOS 14 (this project's deployment target) the
/// adapter returns empty arrays; the observer falls back to `.auto`.
/// Future upgrade: gate these behind `#available(macOS 15.0, *)` and
/// expose variant detail.
@MainActor
struct AVPlayerItemVariantProvider: VariantProviding {
    let item: AVPlayerItem

    var currentVariants: [StreamingVariantSnapshot] {
        []
    }

    var selectedVariant: StreamingVariantSnapshot? {
        nil
    }
}
