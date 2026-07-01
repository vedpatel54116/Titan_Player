import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var session: PlaybackSession
    @StateObject private var libraryViewModel = LibraryViewModel()

    var body: some View {
        HSplitView {
            SidebarView(viewModel: libraryViewModel)
                .frame(minWidth: 200, idealWidth: 250)

            PlayerView()
                .frame(minWidth: 640, minHeight: 480)
        }
        .frame(minWidth: 800, minHeight: 450)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in await session.openFile(url: url) }
        }
        return true
    }
}
