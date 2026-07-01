import simd
import Foundation

struct AudioObject {
    let id: UUID
    var position: SIMD3<Float>
    var gain: Float
    var spread: Float
    var source: AudioObjectSource
    var isActive: Bool = true
}

enum AudioObjectSource {
    case bed(Int)
    case object(Int)
    case ambient(Int)
}
