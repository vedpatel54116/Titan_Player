import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var playerViewModel = PlayerViewModel()
    @StateObject private var libraryViewModel = LibraryViewModel()
    
    var body: some View {
        HSplitView {
            SidebarView(viewModel: libraryViewModel, playerViewModel: playerViewModel)
                .frame(minWidth: 200, idealWidth: 250)
            
            PlayerView(viewModel: playerViewModel)
                .frame(minWidth: 640, minHeight: 480)
        }
        .frame(minWidth: 840, minHeight: 480)
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
                await playerViewModel.openFile(url: url)
            }
        }
        
        return true
    }
}
