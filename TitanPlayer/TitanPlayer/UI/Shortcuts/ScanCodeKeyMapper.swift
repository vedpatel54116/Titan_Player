import AppKit

enum ScanCodeKeyMapper {
    static func keyName(for keyCode: UInt16) -> String? {
        keyNames[keyCode]
    }

    static let keyNames: [UInt16: String] = [
        // Letters
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z",
        7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E",
        15: "R", 16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P",
        37: "L", 38: "J", 40: "K", 45: "N", 46: "M",

        // Digits
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
        22: "6", 26: "7", 28: "8", 25: "9", 29: "0",

        // Symbols
        33: "[", 30: "]", 42: "\\", 43: ",", 44: "/",
        47: ".", 39: "'", 41: ";", 50: "`", 24: "=",
        27: "-",

        // Special keys
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete",
        53: "Escape", 54: "Command", 55: "Shift", 56: "Option",
        57: "Control", 60: "RightShift", 61: "RightOption",
        62: "RightControl", 63: "Fn",

        // Function keys
        120: "F1", 12: "F2", 99: "F3", 118: "F4", 96: "F5",
        97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        104: "F16", 79: "F17", 80: "F18", 90: "F19", 72: "F20",

        // Arrows
        123: "\u{2190}", 124: "\u{2192}", 126: "\u{2191}", 125: "\u{2193}",

        // Navigation
        115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
        114: "Help", 117: "ForwardDelete",

        // Numeric keypad
        65: ".", 67: "*", 69: "/", 71: "=",
        75: "+", 76: "Enter", 78: "-",
        82: "0", 83: "1", 84: "2", 85: "3", 86: "4",
        87: "5", 88: "6", 89: "7", 91: "8", 92: "9",
    ]
}
