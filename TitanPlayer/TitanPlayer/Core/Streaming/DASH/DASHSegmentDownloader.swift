import Foundation

/// Downloads individual DASH segments over HTTP. `DASHStreamSession` owns one
/// and uses it to keep a small look-ahead window of segments in memory so the
/// demuxer never stalls waiting on the network for the next segment.
struct DASHSegmentDownloader: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchData(at url: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let task = session.dataTask(with: url) { data, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data else {
                    continuation.resume(throwing: StreamingError.downloadFailed("Empty segment data for \(url.lastPathComponent)"))
                    return
                }
                continuation.resume(returning: data)
            }
            task.resume()
        }
    }
}
