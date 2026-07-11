import AVFAudio

final class AudioBufferPool {
    private let lock = NSLock()
    private var availableBuffers: [AVAudioFormat: [AVAudioPCMBuffer]] = [:]
    
    func dequeueBuffer(for format: AVAudioFormat, frameCount: AVAudioFrameCount) -> AVAudioPCMBuffer {
        lock.lock()
        defer { lock.unlock() }

        if var buffers = availableBuffers[format], !buffers.isEmpty {
            // Reuse a cached buffer only if its capacity is large enough to
            // hold `frameCount` frames; otherwise we would overflow its
            // allocation when the caller copies `frameCount` samples.
            while let buffer = buffers.popLast() {
                if buffer.frameCapacity >= frameCount {
                    buffer.frameLength = frameCount
                    availableBuffers[format] = buffers
                    return buffer
                }
                // Too small to satisfy this request — drop it.
            }
            availableBuffers[format] = []
        }

        guard let newBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            preconditionFailure("AudioBufferPool: unable to create buffer for format \(format) capacity \(frameCount)")
        }
        return newBuffer
    }
    
    func enqueueBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        
        let format = buffer.format
        if availableBuffers[format] == nil {
            availableBuffers[format] = []
        }
        availableBuffers[format]?.append(buffer)
    }
    
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        availableBuffers.removeAll()
    }
}