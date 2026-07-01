import AppKit
import simd

final class SoftwareTracker {
    var isTracking: Bool = false
    var position: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
    var orientation: simd_quatf = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1))

    private var mouseMonitor: Any?
    private var positionCallback: ((SIMD3<Float>) -> Void)?
    private var orientationCallback: ((simd_quatf) -> Void)?

    init() {
        setupMouseTracking()
    }

    private func setupMouseTracking() {
    }

    func startTracking() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleMouseMovement(to: SIMD3<Float>(
                Float(event.locationInWindow.x) / 1000.0,
                Float(event.locationInWindow.y) / 1000.0,
                0.0
            ))
            return event
        }
        isTracking = true
    }

    func stopTracking() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        isTracking = false
    }

    func handleMouseMovement(to position: SIMD3<Float>) {
        self.position = position
        positionCallback?(position)
    }

    func onPositionUpdate(_ callback: @escaping (SIMD3<Float>) -> Void) {
        positionCallback = callback
    }

    func onOrientationUpdate(_ callback: @escaping (simd_quatf) -> Void) {
        orientationCallback = callback
    }
}
