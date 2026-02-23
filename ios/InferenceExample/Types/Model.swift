import Foundation

enum Model: String, CaseIterable, Identifiable {
  case realtime = "실시간 전사"
  case uploadedFile = "업로드 파일 전사"

  var id: String {
    rawValue
  }

  var name: String {
    rawValue
  }

  var licenseAcnowledgedKey: String {
    "speech.model.\(rawValue)"
  }

  var modelPath: URL? {
    nil
  }
}
