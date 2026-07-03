import AppKit
import Combine
import Foundation

enum DisplayChangeEvent {
    case connected(ExternalDisplayConfig)
    case disconnected(stableID: String)
    case refreshed(ExternalDisplayConfig)
    case primaryChanged(ExternalDisplayConfig)
}

@MainActor
protocol ScreenDetecting: AnyObject {
    func detect(screen: NSScreen) -> ExternalDisplayConfig?
}

@MainActor
final class SystemScreenDetector: ScreenDetecting {
    func detect(screen: NSScreen) -> ExternalDisplayConfig? {
        let detector = DisplayCapabilityDetector()
        let caps = detector.detectCapabilities(for: screen)
        let stableID = stableID(for: screen) ?? autoID(for: screen)
        return ExternalDisplayConfig(
            stableID: stableID,
            displayName: screen.localizedName,
            colorSpaceName: screen.colorSpace?.localizedName,
            colorGamut: caps.colorGamut,
            refreshRate: Float(screen.maximumFramesPerSecond),
            hdrSupported: caps.supportsHDR,
            maxEDRLuminance: caps.maxEDRLuminance,
            lastSeenAt: Date()
        )
    }

    private func stableID(for screen: NSScreen) -> String? {
        if let raw = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
            return ExternalDisplayConfig.cgDisplayID(raw)
        }
        return nil
    }

    private func autoID(for screen: NSScreen) -> String {
        ExternalDisplayConfig.airPlay(
            name: screen.localizedName,
            size: screen.frame.size
        )
    }
}

@MainActor
final class DisplayManager: ObservableObject {
    @Published private(set) var displays: [ExternalDisplayConfig] = []
    @Published private(set) var activeDisplay: ExternalDisplayConfig?
    @Published private(set) var primaryDisplay: ExternalDisplayConfig?
    let events = PassthroughSubject<DisplayChangeEvent, Never>()

    var secondaryDisplay: ExternalDisplayConfig? {
        displays.first(where: { $0.stableID != primaryDisplay?.stableID })
    }

    private let provider: DisplayProviding
    private let detector: ScreenDetecting
    private let persistence: PersistedDisplayConfig
    private var observer: NSObjectProtocol?
    private var lastSeenIDs: Set<String> = []

    init(
        provider: DisplayProviding,
        detector: ScreenDetecting,
        defaults: UserDefaults
    ) {
        self.provider = provider
        self.detector = detector
        self.persistence = PersistedDisplayConfig(defaults: defaults)
        start()
        restorePrimaryDisplay()
    }

    convenience init(defaults: UserDefaults = .standard) {
        self.init(
            provider: SystemDisplayProvider(),
            detector: SystemScreenDetector(),
            defaults: defaults
        )
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func start() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshDisplays() }
        }
        refreshDisplays()
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    func refreshDisplays() {
        let screens = provider.currentScreens()
        var configs: [ExternalDisplayConfig] = []
        for screen in screens {
            if let config = detector.detect(screen: screen) {
                configs.append(config)
            }
        }
        let newIDs = Set(configs.map(\.stableID))
        let removed = lastSeenIDs.subtracting(newIDs)
        for id in removed { events.send(.disconnected(stableID: id)) }
        for config in configs { events.send(.connected(config)) }

        self.displays = configs
        self.lastSeenIDs = newIDs
        if activeDisplay == nil || !newIDs.contains(activeDisplay?.stableID ?? "") {
            activeDisplay = configs.first ?? nil
            if let activeDisplay { events.send(.refreshed(activeDisplay)) }
        } else if let updated = configs.first(where: { $0.stableID == activeDisplay?.stableID }) {
            self.activeDisplay = updated
        }

        // Re-validate primary display
        if primaryDisplay == nil || !newIDs.contains(primaryDisplay?.stableID ?? "") {
            if let promoted = configs.first(where: { $0.stableID != primaryDisplay?.stableID }) ?? configs.first {
                primaryDisplay = promoted
                persistence.savePrimaryDisplayID(promoted.stableID)
            } else {
                primaryDisplay = nil
            }
        }

        try? persistence.merge(newDisplays: configs)
    }

    func setActiveDisplay(stableID: String) {
        guard let next = displays.first(where: { $0.stableID == stableID }) else { return }
        activeDisplay = next
        events.send(.refreshed(next))
    }

    func setPrimaryDisplay(stableID: String) {
        guard let next = displays.first(where: { $0.stableID == stableID }) else { return }
        primaryDisplay = next
        persistence.savePrimaryDisplayID(stableID)
        events.send(.primaryChanged(next))
    }

    private func restorePrimaryDisplay() {
        if let savedID = persistence.loadPrimaryDisplayID(),
           let display = displays.first(where: { $0.stableID == savedID }) {
            primaryDisplay = display
        } else {
            primaryDisplay = displays.first
        }
    }
}
