import AppKit

public protocol DisplayProviding: AnyObject {
    func currentScreens() -> [NSScreen]
}
