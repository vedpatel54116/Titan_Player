import SwiftUI

struct ContentView: View {
    var body: some View {
        HSplitView {
            SidebarView()
                .frame(minWidth: 200, idealWidth: 250)
            
            PlayerView()
                .frame(minWidth: 640, minHeight: 480)
        }
        .frame(minWidth: 840, minHeight: 480)
    }
}
