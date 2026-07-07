import AppKit
import Carbon.HIToolbox

protocol KeyboardLayoutProviding {
    func character(for keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String?
}

enum PhysicalKeyResolver {
    static var layoutProvider: KeyboardLayoutProviding = SystemKeyboardLayoutProvider()

    static func keyString(for event: NSEvent) -> String {
        switch event.specialKey {
        case .leftArrow:  return "leftarrow"
        case .rightArrow: return "rightarrow"
        case .upArrow:    return "uparrow"
        case .downArrow:  return "downarrow"
        default: break
        }

        guard let normalized = normalizeKeyCode(event.keyCode) else {
            return fallbackString(event: event)
        }

        if let resolved = layoutProvider.character(for: normalized, modifiers: event.modifierFlags) {
            return resolved
        }

        return fallbackString(event: event)
    }

    private static func normalizeKeyCode(_ keyCode: UInt16) -> UInt16? {
        switch keyCode {
        case 10:
            return nil
        case 93, 94, 102:
            return nil
        default:
            return keyCode
        }
    }

    private static func fallbackString(event: NSEvent) -> String {
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if chars == " " { return "space" }
        return chars
    }
}

struct SystemKeyboardLayoutProvider: KeyboardLayoutProviding {
    func character(for keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutDataRef = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }

        let layoutData = unsafeBitCast(layoutDataRef, to: CFData.self)
        let keyboardLayout = unsafeBitCast(
            CFDataGetBytePtr(layoutData),
            to: UnsafePointer<UCKeyboardLayout>.self
        )

        var deadKeyState: UInt32 = 0
        var length: Int = 0
        var chars = [UniChar](repeating: 0, count: 4)

        let status = UCKeyTranslate(
            keyboardLayout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDown),
            0,
            UInt32(LMGetKbdType()),
            UInt32(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )

        guard status == noErr, length > 0 else { return nil }

        let result = String(utf16CodeUnits: &chars, count: length).lowercased()
        if result == " " { return "space" }
        return result
    }
}
