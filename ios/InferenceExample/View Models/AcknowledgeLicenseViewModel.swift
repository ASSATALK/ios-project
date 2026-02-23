import Foundation

@MainActor
final class AcknowledgeLicenseViewModel: ObservableObject {
  @Published var acknowledged = true
}
