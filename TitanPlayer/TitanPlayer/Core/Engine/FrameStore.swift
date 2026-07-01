import Metal
import Combine

@MainActor
final class FrameStore {
    private(set) var latestTexture: MTLTexture?
    private(set) var frameID: UInt64 = 0

    private let idSubject = PassthroughSubject<UInt64, Never>()
    /// Publishes `frameID` whenever a new texture is delivered via `update(_:)`.
    var frameIDPublisher: AnyPublisher<UInt64, Never> {
        idSubject.eraseToAnyPublisher()
    }

    func update(_ texture: MTLTexture) {
        self.latestTexture = texture
        frameID &+= 1
        idSubject.send(frameID)
    }
}
