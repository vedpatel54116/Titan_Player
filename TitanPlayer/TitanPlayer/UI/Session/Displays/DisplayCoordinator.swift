import SwiftUI
import Combine
import AppKit
import Metal

@MainActor
final class DisplayCoordinator {
    let displayManager: DisplayManager
    let airPlayController: AirPlayController
    private var secondaryDisplayWindow: ExternalDisplayWindow?
    private var cancellables = Set<AnyCancellable>()

    var rendererProvider: (() -> MetalRenderer?)?
    var audioDelayHandler: ((TimeInterval) -> Void)?

    init(displayManager: DisplayManager, airPlayController: AirPlayController) {
        self.displayManager = displayManager
        self.airPlayController = airPlayController
    }

    func installDisplayBindings() {
        displayManager.$activeDisplay
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] config in
                guard let self else { return }
                guard let screen = ScreenLookup.screen(forStableID: config.stableID),
                      let metal = self.rendererProvider?() else { return }
                metal.updateDisplayCapabilitiesAsynchronously(for: screen)
            }
            .store(in: &cancellables)

        displayManager.events
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .connected(let config):
                    self.handleDisplayConnected(config)
                case .disconnected(let stableID):
                    self.handleDisplayDisconnected(stableID)
                case .primaryChanged(let config):
                    self.handlePrimaryChanged(config)
                case .refreshed:
                    break
                }
            }
            .store(in: &cancellables)

        airPlayController.$currentAudioDelayOffset
            .removeDuplicates()
            .sink { [weak self] offset in
                self?.audioDelayHandler?(offset)
            }
            .store(in: &cancellables)
    }

    private func handleDisplayConnected(_ config: ExternalDisplayConfig) {
        guard config.stableID != displayManager.primaryDisplay?.stableID else { return }
        guard let metal = rendererProvider?() else { return }
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

    private func handleDisplayDisconnected(_ stableID: String) {
        guard let metal = rendererProvider?() else { return }
        metal.removeDisplayTarget(stableID: stableID)

        secondaryDisplayWindow?.close()
        secondaryDisplayWindow = nil
    }

    private func handlePrimaryChanged(_ config: ExternalDisplayConfig) {
        if let screen = ScreenLookup.screen(forStableID: config.stableID),
           let window = NSApp.keyWindow ?? NSApp.windows.first {
            window.setFrameOrigin(screen.frame.origin)
        }

        guard let metal = rendererProvider?() else { return }

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

    func stop() {
        secondaryDisplayWindow?.close()
        secondaryDisplayWindow = nil
    }
}
