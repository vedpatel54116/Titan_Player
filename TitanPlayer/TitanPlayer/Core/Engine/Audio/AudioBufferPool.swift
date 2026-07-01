import AVFAudio

final class AudioBufferPool {
    private let lock = NSLock()
    private var availableBuffers: [AVAudioFormat: [AVAudioPCMBuffer]] = [:]
    
    func dequeueBuffer(for format: AVAudioFormat, frameCount: AVAudioFrameCount) -> AVAudioPCMBuffer {
        lock.lock()
        defer { lock.unlock() }
        
        if var buffers = availableBuffers[format], !buffers.isEmpty {
            let buffer = buffers.removeLast()
            availableBuffers[format] = buffers
            buffer.frameLength = frameCount
            return buffer
        }
        
        return AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
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