import IOKit
import simd

struct TrackingDevice {
    let name: String
    let id: String
    let type: DeviceType
}

enum DeviceType {
    case trackIR
    case mouse
    case keyboard
    case other
}

final class ExternalTracker {
    var isTracking: Bool = false
    var availableDevices: [TrackingDevice] = []

    private var positionCallback: ((SIMD3<Float>) -> Void)?
    private var orientationCallback: ((simd_quatf) -> Void)?

    init() {
        scanForDevices()
    }

    private func scanForDevices() {
        availableDevices = []
    }

    func startTracking(device: TrackingDevice) {
        isTracking = true
    }

    func stopTracking() {
        isTracking = false
    }

    func onPositionUpdate(_ callback: @escaping (SIMD3<Float>) -> Void) {
        positionCallback = callback
    }

    func onOrientationUpdate(_ callback: @escaping (simd_quatf) -> Void) {
        orientationCallback = callback
    }
}
