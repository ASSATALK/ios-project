import SwiftUI

struct ModelSelectionScreen: View {
  var body: some View {
    NavigationStack {
      ConversationScreen()
        .toolbar {
          ToolbarItem(placement: .principal) {
            Text("Realtime + File STT")
              .font(.headline)
          }
        }
    }
  }
}

#Preview {
  ModelSelectionScreen()
}
