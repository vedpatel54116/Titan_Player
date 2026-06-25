import Foundation
import CoreMedia

protocol MediaDemuxing {
    func open(url: URL) async throws -> MediaInfo
    func nextPacket() async throws -> MediaPacket
    func seek(to time: CMTime) async throws
    func close()
}

extension MediaDemuxing {
    func close() {}
}
