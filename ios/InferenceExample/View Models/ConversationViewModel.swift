import Foundation

@MainActor
final class ConversationViewModel: ObservableObject {
  @Published var liveCommittedText = ""
  @Published var liveVolatileText = ""
  @Published var fileTranscriptText = ""
  @Published var statusMessage = "권한 확인 후 실시간 전사를 시작하세요."
  @Published var isRecording = false
  @Published var isBusy = false
  @Published var selectedFileURL: URL?
  @Published var selectedLanguage: OnDeviceModel.LanguageMode = .koreanEnglish

  private let speechEngine = OnDeviceModel()

  init(modelCategory: Model = .realtime) {
    _ = modelCategory
    bindCallbacks()
  }

  var mergedLiveTranscript: String {
    let volatile = liveVolatileText.trimmingCharacters(in: .whitespacesAndNewlines)
    if volatile.isEmpty {
      return liveCommittedText
    }

    if liveCommittedText.isEmpty {
      return volatile
    }

    return "\(liveCommittedText)\n\(volatile)"
  }

  func requestPermissions() async {
    do {
      try await speechEngine.requestPermissions()
      statusMessage = "권한 확인 완료. 전사를 시작할 수 있습니다."
    } catch {
      statusMessage = error.localizedDescription
    }
  }

  func startLiveTranscription() {
    guard !isRecording else { return }

    isBusy = true
    statusMessage = "실시간 전사를 시작하는 중..."

    Task {
      do {
        liveCommittedText = ""
        liveVolatileText = ""
        try await speechEngine.startLive(languageMode: selectedLanguage)

        isRecording = true
        isBusy = false
        statusMessage = "\(selectedLanguage.rawValue) 모드로 실시간 전사 중입니다."
      } catch {
        isRecording = false
        isBusy = false
        statusMessage = error.localizedDescription
      }
    }
  }

  func stopLiveTranscription() {
    guard isRecording else { return }

    isBusy = true
    statusMessage = "전사 세션을 마무리하는 중..."

    Task {
      await speechEngine.stopLive()
      isRecording = false
      isBusy = false
      liveVolatileText = ""
      statusMessage = "실시간 전사가 중지되었습니다."
    }
  }

  func setSelectedFile(url: URL) {
    selectedFileURL = url
    statusMessage = "선택된 파일: \(url.lastPathComponent)"
  }

  func transcribeSelectedFile() {
    guard !isBusy else { return }
    guard let sourceURL = selectedFileURL else {
      statusMessage = "먼저 오디오 파일을 선택해 주세요."
      return
    }

    isBusy = true
    statusMessage = "파일 전사를 수행하는 중..."

    Task {
      do {
        let secureURL = try copyToTemporaryReadableLocation(url: sourceURL)
        let text = try await speechEngine.transcribeFile(
          url: secureURL,
          languageMode: selectedLanguage
        )
        fileTranscriptText = text.isEmpty ? "(전사 결과 없음)" : text
        statusMessage = "\(selectedLanguage.rawValue) 모드 파일 전사 완료"
      } catch {
        statusMessage = "파일 전사 실패: \(error.localizedDescription)"
      }
      isBusy = false
    }
  }

  func clearAll() {
    liveCommittedText = ""
    liveVolatileText = ""
    fileTranscriptText = ""
    statusMessage = "초기화 완료"
  }

  private func bindCallbacks() {
    speechEngine.onVolatileText = { [weak self] text in
      guard let self else { return }
      self.liveVolatileText = text
    }

    speechEngine.onFinalText = { [weak self] text in
      guard let self else { return }
      let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalized.isEmpty else { return }

      if self.liveCommittedText.isEmpty {
        self.liveCommittedText = normalized
      } else {
        self.liveCommittedText += "\n\(normalized)"
      }
    }

    speechEngine.onError = { [weak self] message in
      guard let self else { return }
      self.statusMessage = message
      self.isRecording = false
      self.isBusy = false
    }
  }

  private func copyToTemporaryReadableLocation(url: URL) throws -> URL {
    let hasSecurityScope = url.startAccessingSecurityScopedResource()
    defer {
      if hasSecurityScope {
        url.stopAccessingSecurityScopedResource()
      }
    }

    let fileManager = FileManager.default
    let temporaryURL = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(url.pathExtension)

    if fileManager.fileExists(atPath: temporaryURL.path) {
      try fileManager.removeItem(at: temporaryURL)
    }

    try fileManager.copyItem(at: url, to: temporaryURL)
    return temporaryURL
  }
}
