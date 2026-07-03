import AVFoundation
class TestDelegate: NSObject, AVAssetDownloadDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {}
}
