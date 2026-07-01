import Foundation
import CoreGraphics
@testable import TitanPlayer

final class MockPlayerItem: VariantProviding {
    var currentVariants: [StreamingVariantSnapshot] = []
    var selectedVariant: StreamingVariantSnapshot? = nil
}
