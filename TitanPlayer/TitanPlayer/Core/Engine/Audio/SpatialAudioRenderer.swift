import AVFAudio
import simd

protocol SpatialAudioRenderer: AudioRenderer {
    var spatialAudioEnabled: Bool { get set }
    var headTrackingEnabled: Bool { get set }
    var audioQuality: AudioQuality { get set }

    func setListenerPosition(_ position: SIMD3<Float>)
    func setListenerOrientation(_ orientation: simd_quatf)
    func addAudioObject(_ object: AudioObject)
    func removeAudioObject(_ object: AudioObject)
    func updateAudioObject(_ object: AudioObject, position: SIMD3<Float>)
}
