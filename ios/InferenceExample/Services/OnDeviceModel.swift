import AVFoundation
import Foundation
@preconcurrency
import Speech

final class OnDeviceModel {
  enum LanguageMode: String, CaseIterable, Identifiable {
    case koreanEnglish = "한/영 동시"
    case korean = "한국어"
    case english = "English"

    var id: String { rawValue }

    var primaryLocale: Locale {
      switch self {
      case .koreanEnglish, .korean:
        return Locale(identifier: "ko-KR")
      case .english:
        return Locale(identifier: "en-US")
      }
    }

    var secondaryLocale: Locale? {
      switch self {
      case .koreanEnglish:
        return Locale(identifier: "en-US")
      case .korean, .english:
        return nil
      }
    }
  }

  enum LiveTranscriptionError: LocalizedError {
    case speechPermissionDenied
    case microphonePermissionDenied
    case recognizerUnavailable(String)
    case audioEngineUnavailable
    case noTranscript

    var errorDescription: String? {
      switch self {
      case .speechPermissionDenied:
        return "음성 인식 권한이 거부되었습니다."
      case .microphonePermissionDenied:
        return "마이크 권한이 거부되었습니다."
      case let .recognizerUnavailable(locale):
        return "해당 언어(\(locale))의 음성 인식기를 사용할 수 없습니다."
      case .audioEngineUnavailable:
        return "오디오 엔진을 시작할 수 없습니다."
      case .noTranscript:
        return "전사 결과를 얻지 못했습니다."
      }
    }
  }

  private enum LiveStreamID {
    case primary
    case secondary
  }

  private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isDone = false

    func perform(_ block: () -> Void) {
      lock.lock()
      defer { lock.unlock() }
      guard !isDone else { return }
      isDone = true
      block()
    }
  }

  private final class RecognitionTaskBox: @unchecked Sendable {
    var task: SFSpeechRecognitionTask?
  }

  var onVolatileText: ((String) -> Void)?
  var onFinalText: ((String) -> Void)?
  var onError: ((String) -> Void)?

  private let audioEngine = AVAudioEngine()
  private var livePrimaryTask: SFSpeechRecognitionTask?
  private var liveSecondaryTask: SFSpeechRecognitionTask?
  private var livePrimaryRequest: SFSpeechAudioBufferRecognitionRequest?
  private var liveSecondaryRequest: SFSpeechAudioBufferRecognitionRequest?

  private var currentMode: LanguageMode = .koreanEnglish
  private var latestPrimaryText = ""
  private var latestSecondaryText = ""
  private var isStoppingLive = false

  func requestPermissions() async throws {
    let speechStatus = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status)
      }
    }

    guard speechStatus == .authorized else {
      throw LiveTranscriptionError.speechPermissionDenied
    }

    let micGranted: Bool = await withCheckedContinuation { continuation in
      if #available(iOS 17.0, *) {
        AVAudioApplication.requestRecordPermission { granted in
          continuation.resume(returning: granted)
        }
      } else {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
          continuation.resume(returning: granted)
        }
      }
    }

    guard micGranted else {
      throw LiveTranscriptionError.microphonePermissionDenied
    }
  }

  func startLive(languageMode: LanguageMode) async throws {
    try await requestPermissions()

    await stopLive()

    currentMode = languageMode
    latestPrimaryText = ""
    latestSecondaryText = ""
    isStoppingLive = false

    let primaryLocale = languageMode.primaryLocale
    guard let primaryRecognizer = SFSpeechRecognizer(locale: primaryLocale), primaryRecognizer.isAvailable else {
      throw LiveTranscriptionError.recognizerUnavailable(primaryLocale.identifier)
    }

    let primaryRequest = SFSpeechAudioBufferRecognitionRequest()
    primaryRequest.shouldReportPartialResults = true
    livePrimaryRequest = primaryRequest

    livePrimaryTask = makeLiveTask(
      recognizer: primaryRecognizer,
      request: primaryRequest,
      streamID: .primary
    )

    if let secondaryLocale = languageMode.secondaryLocale {
      guard let secondaryRecognizer = SFSpeechRecognizer(locale: secondaryLocale), secondaryRecognizer.isAvailable else {
        throw LiveTranscriptionError.recognizerUnavailable(secondaryLocale.identifier)
      }

      let secondaryRequest = SFSpeechAudioBufferRecognitionRequest()
      secondaryRequest.shouldReportPartialResults = true
      liveSecondaryRequest = secondaryRequest

      liveSecondaryTask = makeLiveTask(
        recognizer: secondaryRecognizer,
        request: secondaryRequest,
        streamID: .secondary
      )
    }

    let inputNode = audioEngine.inputNode
    let inputFormat = inputNode.outputFormat(forBus: 0)

    inputNode.removeTap(onBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
      guard let self else { return }
      self.livePrimaryRequest?.append(buffer)
      self.liveSecondaryRequest?.append(buffer)
    }

    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.record, mode: .measurement, options: [.allowBluetooth])
      try session.setActive(true, options: .notifyOthersOnDeactivation)
      audioEngine.prepare()
      try audioEngine.start()
    } catch {
      await stopLive()
      throw LiveTranscriptionError.audioEngineUnavailable
    }
  }

  func stopLive() async {
    isStoppingLive = true

    if audioEngine.isRunning {
      audioEngine.inputNode.removeTap(onBus: 0)
      audioEngine.stop()
    }

    livePrimaryRequest?.endAudio()
    liveSecondaryRequest?.endAudio()
    livePrimaryTask?.cancel()
    liveSecondaryTask?.cancel()

    livePrimaryRequest = nil
    liveSecondaryRequest = nil
    livePrimaryTask = nil
    liveSecondaryTask = nil

    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  func transcribeFile(url: URL, languageMode: LanguageMode) async throws -> String {
    try await requestPermissions()

    let primaryLocale = languageMode.primaryLocale
    let primaryLabel = Self.localeLabel(primaryLocale)
    var primaryText: String?
    var secondaryText: String?
    var failures = [String]()

    do {
      primaryText = try await transcribeFileSingle(url: url, locale: primaryLocale)
    } catch {
      failures.append("\(primaryLabel): \(error.localizedDescription)")
    }

    if let secondaryLocale = languageMode.secondaryLocale {
      let secondaryLabel = Self.localeLabel(secondaryLocale)
      do {
        secondaryText = try await transcribeFileSingle(url: url, locale: secondaryLocale)
      } catch {
        failures.append("\(secondaryLabel): \(error.localizedDescription)")
      }
    }

    if languageMode.secondaryLocale == nil {
      if let primaryText {
        return primaryText
      }
      throw NSError(
        domain: "SpeechTranscriber",
        code: -2,
        userInfo: [
          NSLocalizedDescriptionKey: failures.joined(separator: " / ")
        ]
      )
    }

    if let p = primaryText, let s = secondaryText {
      return Self.mergeDualText(primary: p, secondary: s, labeled: true)
    }

    if let p = primaryText {
      return "[KO] \(p)"
    }

    if let s = secondaryText {
      return "[EN] \(s)"
    }

    throw NSError(
      domain: "SpeechTranscriber",
      code: -3,
      userInfo: [
        NSLocalizedDescriptionKey: "한/영 동시 전사 실패: \(failures.joined(separator: " / "))"
      ]
    )
  }

  private func makeLiveTask(
    recognizer: SFSpeechRecognizer,
    request: SFSpeechAudioBufferRecognitionRequest,
    streamID: LiveStreamID
  ) -> SFSpeechRecognitionTask {
    recognizer.recognitionTask(with: request) { [weak self] result, error in
      self?.handleLiveResult(result: result, error: error, streamID: streamID)
    }
  }

  private func handleLiveResult(result: SFSpeechRecognitionResult?, error: Error?, streamID: LiveStreamID) {
    if let result {
      let text = result.bestTranscription.formattedString

      switch streamID {
      case .primary:
        latestPrimaryText = text
      case .secondary:
        latestSecondaryText = text
      }

      let mergedText = mergedLiveText()
      if result.isFinal {
        dispatchToMain {
          self.onFinalText?(mergedText)
        }
      } else {
        dispatchToMain {
          self.onVolatileText?(mergedText)
        }
      }
    }

    if let error, !isStoppingLive {
      dispatchToMain {
        self.onError?("실시간 전사 오류: \(Self.mapSpeechError(error).localizedDescription)")
      }
    }
  }

  private func mergedLiveText() -> String {
    switch currentMode {
    case .korean, .english:
      return latestPrimaryText
    case .koreanEnglish:
      return Self.mergeDualText(primary: latestPrimaryText, secondary: latestSecondaryText, labeled: true)
    }
  }

  private func transcribeFileSingle(url: URL, locale: Locale) async throws -> String {
    do {
      return try await transcribeFileWithURLRequest(url: url, locale: locale)
    } catch {
      if Self.shouldRetryWithBuffer(error) {
        return try await transcribeFileWithBufferRequest(url: url, locale: locale)
      }
      throw Self.mapSpeechError(error)
    }
  }

  private func transcribeFileWithURLRequest(url: URL, locale: Locale) async throws -> String {
    guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
      throw LiveTranscriptionError.recognizerUnavailable(locale.identifier)
    }

    let request = SFSpeechURLRecognitionRequest(url: url)
    request.shouldReportPartialResults = true

    return try await withCheckedThrowingContinuation { continuation in
      let gate = ResumeGate()
      let taskBox = RecognitionTaskBox()
      var lastText = ""

      taskBox.task = recognizer.recognitionTask(with: request) { result, error in
        if let result {
          lastText = result.bestTranscription.formattedString
          if result.isFinal {
            gate.perform {
              taskBox.task?.cancel()
              continuation.resume(returning: lastText)
            }
          }
        }

        if let error {
          if Self.isRecoverableAssistantError(error), !lastText.isEmpty {
            gate.perform {
              taskBox.task?.cancel()
              continuation.resume(returning: lastText)
            }
          } else {
            gate.perform {
              taskBox.task?.cancel()
              continuation.resume(throwing: Self.mapSpeechError(error))
            }
          }
        }
      }

      if taskBox.task == nil {
        gate.perform {
          continuation.resume(throwing: LiveTranscriptionError.noTranscript)
        }
      }
    }
  }

  private func transcribeFileWithBufferRequest(url: URL, locale: Locale) async throws -> String {
    guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
      throw LiveTranscriptionError.recognizerUnavailable(locale.identifier)
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true

    return try await withCheckedThrowingContinuation { continuation in
      let gate = ResumeGate()
      let taskBox = RecognitionTaskBox()
      var lastText = ""

      taskBox.task = recognizer.recognitionTask(with: request) { result, error in
        if let result {
          lastText = result.bestTranscription.formattedString
          if result.isFinal {
            gate.perform {
              taskBox.task?.cancel()
              continuation.resume(returning: lastText)
            }
          }
        }

        if let error {
          if Self.isRecoverableAssistantError(error), !lastText.isEmpty {
            gate.perform {
              taskBox.task?.cancel()
              continuation.resume(returning: lastText)
            }
          } else {
            gate.perform {
              taskBox.task?.cancel()
              continuation.resume(throwing: Self.mapSpeechError(error))
            }
          }
        }
      }

      if taskBox.task == nil {
        gate.perform {
          continuation.resume(throwing: LiveTranscriptionError.noTranscript)
        }
        return
      }

      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let audioFile = try AVAudioFile(forReading: url)
          let format = audioFile.processingFormat
          let frameCount: AVAudioFrameCount = 4096

          while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
              break
            }

            try audioFile.read(into: buffer)
            if buffer.frameLength == 0 {
              break
            }
            request.append(buffer)
          }

          request.endAudio()
        } catch {
          request.endAudio()
          gate.perform {
            taskBox.task?.cancel()
            continuation.resume(throwing: Self.mapSpeechError(error))
          }
        }
      }
    }
  }

  private static func shouldRetryWithBuffer(_ error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == "kAFAssistantErrorDomain" && [1101, 1107, 1110].contains(nsError.code)
  }

  private static func isRecoverableAssistantError(_ error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == "kAFAssistantErrorDomain" && [1101, 1107].contains(nsError.code)
  }

  private static func mapSpeechError(_ error: Error) -> NSError {
    let nsError = error as NSError

    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1107 {
      return NSError(
        domain: "SpeechTranscriber",
        code: 1107,
        userInfo: [
          NSLocalizedDescriptionKey: "파일 전사 실패(1107): 오디오 형식 또는 언어 조합 문제일 수 있습니다. 전사 언어를 파일과 맞추고, wav/m4a 파일로 다시 시도해 주세요."
        ]
      )
    }

    return nsError
  }

  private static func localeLabel(_ locale: Locale) -> String {
    if locale.identifier.hasPrefix("ko") {
      return "KO"
    }
    if locale.identifier.hasPrefix("en") {
      return "EN"
    }
    return locale.identifier
  }

  private static func mergeDualText(primary: String, secondary: String, labeled: Bool) -> String {
    let p = primary.trimmingCharacters(in: .whitespacesAndNewlines)
    let s = secondary.trimmingCharacters(in: .whitespacesAndNewlines)

    if p.isEmpty { return s }
    if s.isEmpty { return p }
    if p == s { return p }

    if labeled {
      return "[KO] \(p)\n[EN] \(s)"
    }

    return p.count >= s.count ? p : s
  }

  private func dispatchToMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread {
      block()
    } else {
      DispatchQueue.main.async(execute: block)
    }
  }
}
