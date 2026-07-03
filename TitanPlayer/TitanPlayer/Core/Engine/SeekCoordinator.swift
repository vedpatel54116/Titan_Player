import Foundation
import CoreMedia
import os

actor SeekCoordinator {
    private var lastSeekTarget: CMTime?
    private var isSeekPending = false
    private let debounceInterval: TimeInterval = 0.1
    private let logger = Logger(subsystem: "com.titanplayer", category: "SeekCoordinator")

    private let seekHandler: (CMTime, Bool) async -> Void

    init(seekHandler: @escaping (CMTime, Bool) async -> Void) {
        self.seekHandler = seekHandler
    }

    func seek(to time: CMTime, accurate: Bool = true) async {
        if isSeekPending {
            lastSeekTarget = time
            return
        }

        isSeekPending = true
        lastSeekTarget = time

        try? await Task.sleep(nanoseconds: UInt64(debounceInterval * 1_000_000_000))

        guard let target = lastSeekTarget else {
            isSeekPending = false
            return
        }

        lastSeekTarget = nil
        isSeekPending = false

        logger.debug("Executing seek to \(target.seconds, privacy: .public)s (accurate=\(accurate))")
        await seekHandler(target, accurate)
    }

    func cancel() {
        lastSeekTarget = nil
        isSeekPending = false
    }
}
