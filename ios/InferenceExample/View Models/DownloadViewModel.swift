import Foundation

@MainActor
final class DownloadViewModel: ObservableObject {
  @Published var progress: Double = 1.0
}
