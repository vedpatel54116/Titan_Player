import AppKit
import Metal

@MainActor
final class ExternalDisplayWindow {
    private var window: NSWindow?
    let metalLayer: CAMetalLayer

    init(device: MTLDevice) {
        self.metalLayer = CAMetalLayer()
        self.metalLayer.device = device
        self.metalLayer.pixelFormat = .rgba16Float
        self.metalLayer.wantsExtendedDynamicRangeContent = true
    }

    func show(on screen: NSScreen) {
        close()

        let screenFrame = screen.frame

        let win = NSWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        win.isOpaque = true
        win.backgroundColor = .black
        win.hasShadow = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false

        let hostView = NSView(frame: screenFrame)
        hostView.wantsLayer = true
        metalLayer.frame = hostView.bounds
        metalLayer.contentsScale = screen.backingScaleFactor
        hostView.layer?.addSublayer(metalLayer)
        win.contentView = hostView

        // Order the window to the front without making it key, so the main
        // player window keeps keyboard focus (and fullscreen toggles target it).
        win.orderFront(nil)
        self.window = win
    }

    func close() {
        window?.close()
        window = nil
    }
}
