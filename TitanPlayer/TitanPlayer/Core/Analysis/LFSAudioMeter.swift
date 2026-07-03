import Foundation
@preconcurrency import AVFAudio
import Accelerate
import Dispatch

/// BS.1770-4 / EBU R128 loudness + true-peak meter. Algorithm verified against
/// libebur128 (canonical reference at https://github.com/jiixyj/libebur128).
final class LFSAudioMeter: @unchecked Sendable {
    /// 5-tap biquad, Direct Form II (canonical): w[n] = x[n] − a1·v1...a4·v4;
    /// y[n] = b0·w + b1·v1 + b2·v2 + b3·v3 + b4·v4.
    private struct Biquad5 {
        let b0, b1, b2, b3, b4: Float
        let a1, a2, a3, a4: Float
        var v1: Float = 0, v2: Float = 0, v3: Float = 0, v4: Float = 0

        mutating func step(_ x: Float) -> Float {
            let w = x - a1*v1 - a2*v2 - a3*v3 - a4*v4
            let y = b0*w + b1*v1 + b2*v2 + b3*v3 + b4*v4
            v4 = v3; v3 = v2; v2 = v1; v1 = w
            return y
        }
    }

    /// Build a single 5-tap K-weighted biquad by bilinear transform of the BS.1770-4
    /// Stage 1 high-shelf (f0=1681.97 Hz, G=4.0 dB, Q=0.707) cascaded with Stage 2
    /// RLB high-pass (f0=38.13 Hz, Q=0.500).
    private static func makeKWeightedBiquad(sampleRate: Double) -> Biquad5 {
        let preF0 = 1681.974450955533
        let preG  = 3.999843853973347
        let preQ  = 0.7071752369554196
        let K  = tan(.pi * preF0 / sampleRate)
        let Vh = pow(10.0, preG / 20.0)
        let Vb = pow(Vh, 0.4996667741545416)
        let a0 = 1 + K/preQ + K*K
        let pb: [Double] = [
            (Vh + Vb*K/preQ + K*K) / a0,
            2 * (K*K - Vh) / a0,
            (Vh - Vb*K/preQ + K*K) / a0
        ]
        let pa: [Double] = [1.0, 2 * (K*K - 1) / a0, (1 - K/preQ + K*K) / a0]

        let rlbF0 = 38.13547087602444
        let rlbQ  = 0.5003270373238773
        let Kr   = tan(.pi * rlbF0 / sampleRate)
        let rb: [Double] = [1.0, -2.0, 1.0]
        let denom = 1 + Kr/rlbQ + Kr*Kr
        let ra: [Double] = [
            1.0,
            2 * (Kr*Kr - 1) / denom,
            (1 - Kr/rlbQ + Kr*Kr) / denom
        ]

        // Convolve pre-filter and RLB into a single 5-tap biquad (matches libebur128).
        let bb = [
            pb[0] * rb[0],
            pb[0] * rb[1] + pb[1] * rb[0],
            pb[0] * rb[2] + pb[1] * rb[1] + pb[2] * rb[0],
            pb[1] * rb[2] + pb[2] * rb[1],
            pb[2] * rb[2]
        ]
        let aa = [
            pa[0] * ra[0],
            pa[0] * ra[1] + pa[1] * ra[0],
            pa[0] * ra[2] + pa[1] * ra[1] + pa[2] * ra[0],
            pa[1] * ra[2] + pa[2] * ra[1],
            pa[2] * ra[2]
        ]
        let inv = Float(1.0 / aa[0])
        return Biquad5(
            b0: Float(bb[0]) * inv,
            b1: Float(bb[1]) * inv,
            b2: Float(bb[2]) * inv,
            b3: Float(bb[3]) * inv,
            b4: Float(bb[4]) * inv,
            a1: Float(aa[1]) * inv,
            a2: Float(aa[2]) * inv,
            a3: Float(aa[3]) * inv,
            a4: Float(aa[4]) * inv
        )
    }

    /// Polyphase FIR for 4× (or 2×) oversampling true-peak detection, BS.1770-3 Annex.
    /// Matches libebur128's `interp_create` algorithm: Hanning-windowed sinc,
    /// decomposed into per-phase sub-filters driven by a cyclic delay line.
    private struct Polyphase {
        let factor: Int
        let delay: Int
        var filters: [[Float]]
        var z: [Float]
        var zi: Int = 0

        static func make(taps: Int, factor: Int) -> Polyphase {
            let delay = (taps + factor - 1) / factor
            var filters = Array(repeating: [Float](), count: factor)
            for j in 0..<taps {
                let m = Double(j) - Double(taps - 1) / 2.0
                let absM = abs(m)
                var c: Double
                if absM < 1e-6 {
                    c = 1.0
                } else {
                    let argument = m * .pi / Double(factor)
                    c = sin(argument) / argument
                }
                let hannArg = 2.0 * .pi * Double(j) / Double(taps - 1)
                let hann = 0.5 * (1.0 - cos(hannArg))
                c *= hann
                if abs(c) > 1e-6 {
                    let phase = j % factor
                    filters[phase].append(Float(c))
                }
            }
            return Polyphase(factor: factor, delay: delay, filters: filters, z: [])
        }

        mutating func process(_ samples: [Float]) -> [Float] {
            if z.isEmpty { z = Array(repeating: 0, count: delay) }
            var out: [Float] = []
            out.reserveCapacity(samples.count * factor)
            for x in samples {
                z[zi] = x
                for p in 0..<factor {
                    var acc: Float = 0
                    for k in 0..<filters[p].count {
                        var idx = zi - k
                        if idx < 0 { idx += delay }
                        acc += z[idx] * filters[p][k]
                    }
                    out.append(acc)
                }
                zi += 1
                if zi == delay { zi = 0 }
            }
            return out
        }
    }

    private let sampleRate: Double
    private let channelCount: Int
    private var filters: [Biquad5]
    private let queue = DispatchQueue(label: "com.titanplayer.analysis.audio",
                                      qos: .userInteractive)
    private let samplesPer100ms: Int

    // Block accumulator
    private var msBlockSumSquares: [Float]      // per-channel running sum within a 100 ms block
    private var msSamplesAccumulated: Int = 0
    private var momentaryRing: [Float] = []     // ring of channel-summed mean-squares, max 4 entries
    private var shortTermRing: [Float] = []     // ring of channel-summed mean-squares, max 30 entries
    private var integratedBlocks: [Float] = []  // finished 400 ms blocks (channel-summed mean-squares)

    // True peak
    private var interpolator: Polyphase?
    private var truePeakHold: (value: Float, until: Date) =
        (-120.0, Date(timeIntervalSince1970: 0))

    @MainActor private(set) var metering: AudioMeteringData = .zero

    init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.samplesPer100ms = Int((sampleRate + 5) / 10)
        self.filters = (0..<channelCount).map { _ in
            LFSAudioMeter.makeKWeightedBiquad(sampleRate: sampleRate)
        }
        self.msBlockSumSquares = Array(repeating: 0, count: channelCount)
        if sampleRate < 96_000 {
            self.interpolator = Polyphase.make(taps: 49, factor: 4)
        } else if sampleRate < 192_000 {
            self.interpolator = Polyphase.make(taps: 49, factor: 2)
        }
    }

    /// Reset all state (filter history, blocks, peak hold) to zero.
    func reset() {
        for ch in 0..<channelCount {
            filters[ch].v1 = 0; filters[ch].v2 = 0
            filters[ch].v3 = 0; filters[ch].v4 = 0
            msBlockSumSquares[ch] = 0
        }
        msSamplesAccumulated = 0
        momentaryRing.removeAll()
        shortTermRing.removeAll()
        integratedBlocks.removeAll()
        if var interp = interpolator { interp.zi = 0; interpolator = interp }
        truePeakHold = (-120.0, Date(timeIntervalSince1970: 0))
        Task { @MainActor in self.metering = .zero }
    }

    func consume(buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            self?.processBufferSync(buffer)
        }
    }

    /// Ingest a decoded `AudioFrame` (interleaved or planar `[Float]`). Converts to
    /// a de-interleaved `AVAudioPCMBuffer` and feeds it through the meter pipeline.
    func consume(frame: AudioFrame) {
        let ch  = frame.format.channels
        let rate = frame.format.sampleRate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate),
                                        channels: AVAudioChannelCount(ch)) else { return }
        let total = frame.buffer.count
        let frames = total / ch
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames)) else { return }
        buf.frameLength = UInt32(frames)
        let src = frame.buffer
        if frame.format.isInterleaved {
            for c in 0..<ch {
                let dst = buf.floatChannelData![c]
                for i in 0..<frames { dst[i] = src[i * ch + c] }
            }
        } else {
            for c in 0..<ch {
                let dst = buf.floatChannelData![c]
                for i in 0..<frames { dst[i] = src[c * frames + i] }
            }
        }
        consume(buffer: buf)
    }

    private func processBufferSync(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)

        // Snapshot channels for true-peak analysis (must capture before K-filtering).
        var snapshots: [[Float]] = []
        if interpolator != nil {
            snapshots.reserveCapacity(channelCount)
            for ch in 0..<channelCount {
                let p = channels[ch]
                var snap = [Float](repeating: 0, count: frames)
                for i in 0..<frames { snap[i] = p[i] }
                snapshots.append(snap)
            }
        }

        // K-filter + block accumulator
        for i in 0..<frames {
            for ch in 0..<channelCount {
                let y = filters[ch].step(channels[ch][i])
                msBlockSumSquares[ch] += y * y
            }
            msSamplesAccumulated += 1
            if msSamplesAccumulated >= samplesPer100ms {
                flushBlock()
                msSamplesAccumulated = 0
                for ch in 0..<channelCount { msBlockSumSquares[ch] = 0 }
            }
        }

        // True-peak per channel via polyphase upsampling.
        if var interp = interpolator {
            var maxPeak: Float = 0
            for ch in 0..<channelCount {
                let upsampled = interp.process(snapshots[ch])
                for v in upsampled { maxPeak = max(maxPeak, abs(v)) }
            }
            updateTruePeak(maxPeak)
        }
    }

    private func flushBlock() {
        let n = Float(samplesPer100ms)
        var channelSumMS: Float = 0
        for ch in 0..<channelCount {
            channelSumMS += msBlockSumSquares[ch] / n
        }
        momentaryRing.append(channelSumMS)
        if momentaryRing.count > 4 { momentaryRing.removeFirst() }
        shortTermRing.append(channelSumMS)
        if shortTermRing.count > 30 { shortTermRing.removeFirst() }
        // Every 4 blocks = 400 ms window for integrated gating (75% overlap with the next).
        if momentaryRing.count == 4 {
            let mm: Float = momentaryRing.reduce(0, +) / 4
            integratedBlocks.append(mm)
            if integratedBlocks.count > 4096 { integratedBlocks.removeFirst() }
        }
        publish()
    }

    /// Compute momentary / short-term / integrated (with two-stage gating) loudness
    /// and publish the result on the main actor.
    private func publish() {
        let momentaryMS: Float = momentaryRing.isEmpty
            ? 1e-12
            : momentaryRing.reduce(0, +) / Float(momentaryRing.count)
        let momentaryLUFS = -0.691 + 10 * log10f(max(momentaryMS, 1e-12))

        let stMS: Float = shortTermRing.isEmpty
            ? 1e-12
            : shortTermRing.reduce(0, +) / Float(shortTermRing.count)
        let shortTermLUFS = -0.691 + 10 * log10f(max(stMS, 1e-12))

        // Integrated loudness with BS.1770-4 two-stage gating.
        let absGateMS: Float = powf(10.0, (-70.0 + 0.691) / 10.0)  // ≈ 1.174e-7
        let stageA = integratedBlocks.filter { $0 >= absGateMS }
        var integratedLUFS: Float? = nil
        if !stageA.isEmpty {
            let ungatedMS: Float = stageA.reduce(0, +) / Float(stageA.count)
            let relGateMS: Float = ungatedMS * powf(10.0, -10.0 / 10.0)  // exactly -10 LU
            let stageB = stageA.filter { $0 >= relGateMS }
            if !stageB.isEmpty {
                let gatedMS: Float = stageB.reduce(0, +) / Float(stageB.count)
                integratedLUFS = -0.691 + 10 * log10f(max(gatedMS, 1e-12))
            }
        }

        Task { @MainActor in
            let snapshot = self.metering
            // Preserve true-peak fields from the most recent true-peak update.
            self.metering = AudioMeteringData(
                momentaryLUFS: momentaryLUFS,
                shortTermLUFS: shortTermLUFS,
                integratedLUFS: integratedLUFS,
                truePeakDBTP: snapshot.truePeakDBTP,
                peakHoldDBTP: snapshot.peakHoldDBTP
            )
        }
    }

    private func updateTruePeak(_ peak: Float) {
        let now = Date()
        let dbTP = 20.0 * log10f(max(peak, 1e-6))
        if dbTP >= truePeakHold.value || now >= truePeakHold.until {
            truePeakHold = (value: dbTP, until: now.addingTimeInterval(1.5))
        } else {
            // release at –0.5 dB/s for the duration after the hold window expired
            let elapsed = now.timeIntervalSince(truePeakHold.until.addingTimeInterval(-1.5))
            let release = Float(min(elapsed, 5.0)) * 0.5
            truePeakHold.value -= release
        }
        let hold = truePeakHold
        Task { @MainActor in
            let snapshot = self.metering
            self.metering = AudioMeteringData(
                momentaryLUFS: snapshot.momentaryLUFS,
                shortTermLUFS: snapshot.shortTermLUFS,
                integratedLUFS: snapshot.integratedLUFS,
                truePeakDBTP: dbTP,
                peakHoldDBTP: PeakHoldSample(value: hold.value, holdUntil: hold.until)
            )
        }
    }
}
