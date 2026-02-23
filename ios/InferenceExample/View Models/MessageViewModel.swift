import Foundation

struct MessageViewModel: Identifiable {
  let id = UUID()
  let text: String
  let isFinal: Bool
}
