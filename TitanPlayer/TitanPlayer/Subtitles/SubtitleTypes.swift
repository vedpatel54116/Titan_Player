import Foundation

struct SubtitleEvent {
    let startTime: Double
    let endTime: Double
    let text: AttributedString
    let position: SubtitlePosition
    let style: SubtitleStyle
}

enum SubtitlePosition {
    case bottom
    case top
    case custom(x: Double, y: Double)
}

struct SubtitleStyle {
    let fontSize: CGFloat
    let fontName: String
    let foregroundColor: SubtitleColor
    let backgroundColor: SubtitleColor?
    let isBold: Bool
    let isItalic: Bool
    
    static let `default` = SubtitleStyle(
        fontSize: 24,
        fontName: "Helvetica",
        foregroundColor: .white,
        backgroundColor: .init(r: 0, g: 0, b: 0, a: 0.7),
        isBold: false,
        isItalic: false
    )
}

struct SubtitleColor {
    let r: Double
    let g: Double
    let b: Double
    let a: Double
    
    static let white = SubtitleColor(r: 1, g: 1, b: 1, a: 1)
    static let yellow = SubtitleColor(r: 1, g: 1, b: 0, a: 1)
}

struct SubtitleTrack: Hashable {
    let name: String
    let language: String?
    let isDefault: Bool
    let events: [SubtitleEvent]
    
    static func == (lhs: SubtitleTrack, rhs: SubtitleTrack) -> Bool {
        lhs.name == rhs.name
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}
