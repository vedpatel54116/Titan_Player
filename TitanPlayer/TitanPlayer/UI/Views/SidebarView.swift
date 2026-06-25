import SwiftUI

struct SidebarView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Library")
                .font(.headline)
            Text("No media loaded")
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding()
    }
}
