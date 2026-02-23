import Foundation

@MainActor
final class HuggingFaceFlowViewModel: ObservableObject {
  @Published var statusText = "Not used in Speech mode"
}
