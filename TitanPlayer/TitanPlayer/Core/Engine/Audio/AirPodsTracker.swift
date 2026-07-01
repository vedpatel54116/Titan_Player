import CoreMotion
import simd

final class AirPodsTracker {
    private let motionManager = CMHeadphoneMotionManager()
    var isTracking: Bool = false

    private var positionCallback: ((SIMD3<Float>) -> Void)?
    private var orientationCallback: ((simd_quatf) -> Void)?

    init() {
        setupMotionManager()
    }

    private func setupMotionManager() {
    }

    func startTracking() {
        guard motionManager.isDeviceMotionAvailable else {
            return
        }

        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion = motion else { return }

            let orientation = motion.attitude.quaternion
            let quat = simd_quatf(
                ix: Float(orientation.x),
                iy: Float(orientation.y),
                iz: Float(orientation.z),
                r: Float(orientation.w)
            )

            self?.orientationCallback?(quat)
        }

        isTracking = true
    }

    func stopTracking() {
        motionManager.stopDeviceMotionUpdates()
        isTracking = false
    }

    func onPositionUpdate(_ callback: @escaping (SIMD3<Float>) -> Void) {
        positionCallback = callback
    }

    func onOrientationUpdate(_ callback: @escaping (simd_quatf) -> Void) {
        orientationCallback = callback
    }
}
