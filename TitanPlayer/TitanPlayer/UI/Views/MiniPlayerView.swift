import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject var session: PlaybackSession
    @State private var showControls = true
    @State private var hideWorkItem: DispatchWorkItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if session.isAudioOnly {
                AudioOnlyView(compact: true)
            } else if session.isMediaLoaded {
                MirrorMTKView(frameStore: session.frameStore)
                    .aspectRatio(contentMode: session.effectiveFitMode == .fill ? .fill : .fit)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 32))
                    .foregroundColor(.gray)
            }

            VStack {
                Spacer()
                if showControls {
                    MiniControlBar()
                        .transition(.opacity)
                }
            }

            Color.clear
                .background {
                    KeyListenerView(session: session)
                }
                .background(TouchBarProvider(session: session, compact: true))
        }
        .frame(width: 320, height: 180)
        .configureWindow { window in
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isMovable = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.borderless)
        }
        .onAppear { startHideTimer() }
        .onChange(of: session.playState) { newstate in
            if newstate == .playing {
                startHideTimer()
            } else {
                cancelHideTimer()
                withAnimation { showControls = true }
            }
        }
        .onHover { _ in revealControls() }
        .onTapGesture { revealControls() }
    }

    private func revealControls() {
        withAnimation { showControls = true }
        hideWorkItem?.cancel()
        if session.playState == .playing {
            let work = DispatchWorkItem { showControls = false }
            hideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }

    private func startHideTimer() { revealControls() }
    private func cancelHideTimer() { hideWorkItem?.cancel(); hideWorkItem = nil }
}
