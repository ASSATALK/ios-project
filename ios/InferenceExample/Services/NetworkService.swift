import Foundation

enum NetworkService {
  static func buildError(_ text: String) -> NSError {
    NSError(domain: "InferenceExample.Network", code: -1, userInfo: [NSLocalizedDescriptionKey: text])
  }
}
