import simd

enum TrackingSource {
    case airpods
    case external
    case software
}

final class HeadTrackingManager {
    var trackingSource: TrackingSource = .software
    var position: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
    var orientation: simd_quatf = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1))

    private var positionCallback: ((SIMD3<Float>) -> Void)?
    private var orientationCallback: ((simd_quatf) -> Void)?

    init() {
        setupTracking()
    }

    private func setupTracking() {
    }

    func updatePosition(_ position: SIMD3<Float>) {
        self.position = position
        positionCallback?(position)
    }

    func updateOrientation(_ orientation: simd_quatf) {
        self.orientation = orientation
        orientationCallback?(orientation)
    }

    func onPositionUpdate(_ callback: @escaping (SIMD3<Float>) -> Void) {
        positionCallback = callback
    }

    func onOrientationUpdate(_ callback: @escaping (simd_quatf) -> Void) {
        orientationCallback = callback
    }
}
