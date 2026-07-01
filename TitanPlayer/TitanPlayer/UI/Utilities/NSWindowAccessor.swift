import SwiftUI
import AppKit

struct NSWindowAccessor: NSViewRepresentable {
    var configuration: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let view = view else { return }
            if let window = view.window {
                configuration(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            configuration(window)
        }
    }
}

extension View {
    func configureWindow(_ configuration: @escaping (NSWindow) -> Void) -> some View {
        background(NSWindowAccessor(configuration: configuration))
    }
}
