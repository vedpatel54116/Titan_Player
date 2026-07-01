import AppKit

@MainActor
enum ScreenLookup {
    static func screen(forStableID stableID: String) -> NSScreen? {
        for screen in NSScreen.screens {
            if let raw = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
               ExternalDisplayConfig.cgDisplayID(raw) == stableID {
                return screen
            }
            let alt = ExternalDisplayConfig.airPlay(
                name: screen.localizedName,
                size: screen.frame.size
            )
            if alt == stableID { return screen }
        }
        return nil
    }
}
