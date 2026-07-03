import Combine
import AppKit
import Metal
import AVKit

@MainActor
final class DisplayCoordinator {
    let displayManager: DisplayManager
    let airPlayController: AirPlayController

    private var secondaryDisplayWindow: ExternalDisplayWindow?
    private var cancellables = Set<AnyCancellable>()

    init(airPlayPlayer: AVPlayer) {
        self.displayManager = DisplayManager()
        self.airPlayController = AirPlayController(monitor: airPlayPlayer)
    }

    func installDisplayBindings(
        renderer: FrameRendering?,
        engine: PlaybackEngine
    ) {
        displayManager.$activeDisplay
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak renderer] config in
                guard let screen = ScreenLookup.screen(forStableID: config.stableID),
                      let metal = renderer as? MetalRenderer else { return }
                metal.updateDisplayCapabilitiesAsynchronously(for: screen)
            }
            .store(in: &cancellables)

        displayManager.events
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .connected(let config):
                    self.handleDisplayConnected(config, renderer: renderer)
                case .disconnected(let stableID):
                    self.handleDisplayDisconnected(stableID, renderer: renderer)
                case .primaryChanged(let config):
                    self.handlePrimaryChanged(config, renderer: renderer)
                case .refreshed:
                    break
                }
            }
            .store(in: &cancellables)

        airPlayController.$currentAudioDelayOffset
            .removeDuplicates()
            .sink { [weak engine] offset in
                engine?.setAudioDelay(offset)
            }
            .store(in: &cancellables)
    }

    func teardown() {
        secondaryDisplayWindow?.close()
        secondaryDisplayWindow = nil
        cancellables.removeAll()
    }

    // MARK: - Private

    private func handleDisplayConnected(
        _ config: ExternalDisplayConfig,
        renderer: FrameRendering?
    ) {
        guard config.stableID != displayManager.primaryDisplay?.stableID else { return }
        guard let metal = renderer as? MetalRenderer else { return }
        guard let screen = ScreenLookup.screen(forStableID: config.stableID) else { return }

        let detector = DisplayCapabilityDetector()
        let caps = detector.detectCapabilities(for: screen)
        let icc = detector.detectICCProfile(for: screen)

        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let window = ExternalDisplayWindow(device: device)
        window.show(on: screen)
        secondaryDisplayWindow = window

        metal.addDisplayTarget(
            stableID: config.stableID,
            layer: window.metalLayer,
            capabilities: caps,
            iccProfile: icc
        )
    }

    private func handleDisplayDisconnected(
        _ stableID: String,
        renderer: FrameRendering?
    ) {
        guard let metal = renderer as? MetalRenderer else { return }
        metal.removeDisplayTarget(stableID: stableID)

        secondaryDisplayWindow?.close()
        secondaryDisplayWindow = nil
    }

    private func handlePrimaryChanged(
        _ config: ExternalDisplayConfig,
        renderer: FrameRendering?
    ) {
        if let screen = ScreenLookup.screen(forStableID: config.stableID),
           let window = NSApp.keyWindow ?? NSApp.windows.first {
            window.setFrameOrigin(screen.frame.origin)
        }

        guard let metal = renderer as? MetalRenderer else { return }

        if let oldSecondary = displayManager.secondaryDisplay {
            metal.removeDisplayTarget(stableID: oldSecondary.stableID)
            secondaryDisplayWindow?.close()
            secondaryDisplayWindow = nil
        }

        if let secondary = displayManager.secondaryDisplay,
           let screen = ScreenLookup.screen(forStableID: secondary.stableID) {
            let detector = DisplayCapabilityDetector()
            let caps = detector.detectCapabilities(for: screen)
            let icc = detector.detectICCProfile(for: screen)

            guard let device = MTLCreateSystemDefaultDevice() else { return }
            let window = ExternalDisplayWindow(device: device)
            window.show(on: screen)
            secondaryDisplayWindow = window

            metal.addDisplayTarget(
                stableID: secondary.stableID,
                layer: window.metalLayer,
                capabilities: caps,
                iccProfile: icc
            )
        }
    }
}
