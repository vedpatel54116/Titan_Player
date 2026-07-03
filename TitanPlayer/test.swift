import AVFoundation
class TestDelegate: NSObject, AVAssetDownloadDelegate {
    func urlSession(_ session: URLSession,
                    aggregateAssetDownloadTask task: AVAggregateAssetDownloadTask,
                    didLoad timeRange: CMTimeRange,
                    totalTimeRangesLoaded loadedTimeRanges: [NSValue],
                    timeRangeExpectedToLoad expected: CMTimeRange,
                    for mediaSelection: AVMediaSelection) {}
}
