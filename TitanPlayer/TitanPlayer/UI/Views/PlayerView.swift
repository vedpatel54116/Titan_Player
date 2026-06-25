import SwiftUI
import UniformTypeIdentifiers

struct PlayerView: View {
    @ObservedObject var viewModel: PlayerViewModel
    @State private var isHovering = false
    
    var body: some View {
        ZStack {
            // Video content
            VideoContentView(viewModel: viewModel)
            
            // Subtitle overlay
            SubtitleOverlay(events: viewModel.currentSubtitleEvents)
            
            // Controls overlay (shows on hover)
            if isHovering || viewModel.playState != .playing {
                VStack {
                    Spacer()
                    ControlBar(viewModel: viewModel)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.3)) {
                isHovering = hovering
            }
        }
        .onTapGesture(count: 2) {
            // Toggle fullscreen
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else {
                return
            }
            
            Task { @MainActor in
                await viewModel.openFile(url: url)
            }
        }
        
        return true
    }
}

struct VideoContentView: View {
    @ObservedObject var viewModel: PlayerViewModel
    
    var body: some View {
        ZStack {
            Color.black
            
            if viewModel.playState == .idle {
                VStack(spacing: 16) {
                    Image(systemName: "film")
                        .font(.system(size: 64))
                        .foregroundColor(.gray)
                    
                    Text("Drop a video file here")
                        .foregroundColor(.gray)
                    
                    Text("or use File > Open")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            } else if viewModel.playState == .loading {
                ProgressView("Loading...")
                    .foregroundColor(.white)
            }
        }
    }
}

struct SubtitleOverlay: View {
    let events: [SubtitleEvent]
    
    var body: some View {
        VStack {
            Spacer()
            
            ForEach(events, id: \.startTime) { event in
                Text(event.text)
                    .font(.system(size: event.style.fontSize))
                    .foregroundColor(Color(
                        red: event.style.foregroundColor.r,
                        green: event.style.foregroundColor.g,
                        blue: event.style.foregroundColor.b
                    ))
                    .shadow(color: .black, radius: 2)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 60)
            }
        }
    }
}
