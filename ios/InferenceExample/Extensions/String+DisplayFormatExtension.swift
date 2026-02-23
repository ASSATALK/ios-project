import Foundation

extension String {
  var collapsedWhitespace: String {
    components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}
