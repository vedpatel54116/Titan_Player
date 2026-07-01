import Foundation

struct PeakHoldSample: Equatable {
    var value: Float
    var holdUntil: Date
}

struct AudioMeteringData: Equatable {
    var momentaryLUFS: Float
    var shortTermLUFS: Float
    var integratedLUFS: Float?
    var truePeakDBTP: Float
    var peakHoldDBTP: PeakHoldSample

    init(momentaryLUFS: Float,
         shortTermLUFS: Float,
         integratedLUFS: Float?,
         truePeakDBTP: Float,
         peakHoldDBTP: PeakHoldSample) {
        self.momentaryLUFS = momentaryLUFS
        self.shortTermLUFS = shortTermLUFS
        self.integratedLUFS = integratedLUFS
        self.truePeakDBTP = truePeakDBTP
        self.peakHoldDBTP = peakHoldDBTP
    }

    static let zero = AudioMeteringData(
        momentaryLUFS: -120.0,
        shortTermLUFS: -120.0,
        integratedLUFS: nil,
        truePeakDBTP: -120.0,
        peakHoldDBTP: PeakHoldSample(value: -120.0,
                                     holdUntil: Date(timeIntervalSince1970: 0))
    )
}
