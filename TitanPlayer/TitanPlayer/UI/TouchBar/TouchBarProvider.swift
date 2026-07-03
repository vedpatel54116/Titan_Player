import SwiftUI
import AppKit

struct TouchBarProvider: NSViewRepresentable {
    let session: PlaybackSession
    let compact: Bool

    init(session: PlaybackSession, compact: Bool = false) {
        self.session = session
        self.compact = compact
    }

    func makeNSView(context: Context) -> TouchBarHostView {
        let host = TouchBarHostView()
        host.attach(session: session)
        host.compact = compact
        return host
    }

    func updateNSView(_ nsView: TouchBarHostView, context: Context) {
        nsView.attach(session: session)
        nsView.compact = compact
        nsView.refreshState()
    }
}

final class TouchBarHostView: NSView {
    private var controller: TouchBarController?
    private weak var session: PlaybackSession?

    var compact: Bool = false {
        didSet {
            touchBar = makeTouchBar()
        }
    }

    override var acceptsFirstResponder: Bool { true }

    func attach(session: PlaybackSession) {
        if self.session !== session {
            self.session = session
            let side = DispatcherSideEffects(
                toggleFullscreen: { NSApp.keyWindow?.toggleFullScreen(nil) },
                toggleMiniPlayer: { [session] in
                    SessionLocator.MiniWindowController.shared.toggle(
                        using: { _ in MiniPlayerView() },
                        session: session
                    )
                },
                newLibraryWindow: { TitanCommands.openLibraryPanel() },
                openFile:         { TitanCommands.openFileUsingPanel(session: session) }
            )
            let dispatcher = PlayerActionDispatcher(session: session, sideEffects: side)
            if controller == nil {
                controller = TouchBarController(session: session)
            }
            controller?.openMini = side.toggleMiniPlayer
            controller?.newLibraryWindow = side.newLibraryWindow
            controller?.session = session
            _ = dispatcher
            touchBar = makeTouchBar()
        }
    }

    func refreshState() {
        // The NSTouchBar delegate is consulted on demand: when the user
        // elects to view the bar, AppKit calls `makeItem(forIdentifier:)`
        // for each identifier again, so state shown on bar items (icons,
        // volume value, time label) is recomputed from the current session.
        touchBar = makeTouchBar()
    }
}

extension TouchBarHostView {
    override func makeTouchBar() -> NSTouchBar? {
        let bar = NSTouchBar()
        bar.delegate = self
        if compact {
            bar.defaultItemIdentifiers = [.transport, .timeLabel]
        } else {
            bar.defaultItemIdentifiers = [.scrubber, .transport, .volume, .mini]
        }
        return bar
    }
}

extension TouchBarHostView: NSTouchBarDelegate {
    func touchBar(_ touchBar: NSTouchBar,
                  makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch identifier {
        case .scrubber:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let scrubber = NSScrubber()
            scrubber.isContinuous = true
            scrubber.dataSource = self
            scrubber.delegate = self
            scrubber.selectedIndex = currentMinuteIndex()
            item.view = scrubber
            return item
        case .transport:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let stack = NSStackView()
            stack.orientation = .horizontal
            let back = NSButton(title: "−10",
                                target: controller,
                                action: #selector(TouchBarController.skipBackward))
            let play = NSButton(title: playPauseTitle(),
                                target: controller,
                                action: #selector(TouchBarController.togglePlayPause))
            let fwd  = NSButton(title: "+10",
                                target: controller,
                                action: #selector(TouchBarController.skipForward))
            stack.addArrangedSubview(back)
            stack.addArrangedSubview(play)
            stack.addArrangedSubview(fwd)
            item.view = stack
            return item
        case .volume:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let slider = NSSlider(value: Double(session?.volume ?? 1.0),
                                  minValue: 0, maxValue: 1,
                                  target: controller,
                                  action: #selector(TouchBarController.volumeChanged(_:)))
            item.view = slider
            return item
        case .timeLabel:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = NSTextField(labelWithString: timeLabelText())
            return item
        case .mini:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let button = NSButton(title: "Mini",
                                  target: controller,
                                  action: #selector(TouchBarController.openMiniPlayer))
            item.view = button
            return item
        default:
            return nil
        }
    }

    private func playPauseTitle() -> String {
        guard let session else { return "▶︎" }
        return session.playState == .playing ? "❚❚" : "▶︎"
    }

    private func timeLabelText() -> String {
        guard let session else { return "0:00 / 0:00" }
        return "\(format(session.currentTime)) / \(format(session.duration))"
    }

    private func format(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return "\(s/60):\(String(format: "%02d", s%60))"
    }

    private func currentMinuteIndex() -> Int {
        guard let session else { return 0 }
        let mins = Int(session.currentTime / 60)
        return max(0, min(mins, max(1, minuteCount()) - 1))
    }

    private func minuteCount() -> Int {
        guard let session else { return 1 }
        guard session.duration > 0 else { return 1 }
        return max(1, Int(session.duration / 60) + 1)
    }
}

extension TouchBarHostView: NSScrubberDataSource, NSScrubberDelegate {
    func numberOfItems(for scrubber: NSScrubber) -> Int {
        return minuteCount()
    }

    func scrubber(_ scrubber: NSScrubber, viewForItemAt index: Int) -> NSScrubberItemView {
        let view = NSScrubberTextItemView()
        view.textField.stringValue = "\(index):00"
        return view
    }

    func scrubber(_ scrubber: NSScrubber, didSelectItemAt index: Int) {
        guard let controller, let session else { return }
        let targetSeconds = Double(index) * 60.0
        let clamped = min(targetSeconds, max(0, session.duration))
        Task { await session.seek(to: clamped) }
        _ = controller
    }
}

private extension NSTouchBarItem.Identifier {
    static let scrubber  = NSTouchBarItem.Identifier("titanplayer.scrubber")
    static let transport = NSTouchBarItem.Identifier("titanplayer.transport")
    static let volume    = NSTouchBarItem.Identifier("titanplayer.volume")
    static let timeLabel = NSTouchBarItem.Identifier("titanplayer.timelabel")
    static let mini      = NSTouchBarItem.Identifier("titanplayer.mini")
}
