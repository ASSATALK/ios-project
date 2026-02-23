import AVFoundation
import Foundation
import Speech

final class OnDeviceModel {
  enum LiveTranscriptionError: LocalizedError {
    case speechPermissionDenied
    case microphonePermissionDenied
    case recognizerUnavailable
    case audioEngineUnavailable
    case noTranscript

    var errorDescription: String? {
      switch self {
      case .speechPermissionDenied:
        return "음성 인식 권한이 거부되었습니다."
      case .microphonePermissionDenied:
        return "마이크 권한이 거부되었습니다."
      case .recognizerUnavailable:
        return "선택한 언어에 대한 음성 인식기를 사용할 수 없습니다."
      case .audioEngineUnavailable:
        return "오디오 엔진을 시작할 수 없습니다."
      case .noTranscript:
        return "전사 결과를 얻지 못했습니다."
      }
    }
  }

  var onVolatileText: ((String) -> Void)?
  var onFinalText: ((String) -> Void)?
  var onError: ((String) -> Void)?

  private let audioEngine = AVAudioEngine()
  private var liveRecognitionTask: SFSpeechRecognitionTask?
  private var liveRecognitionRequest: SFSpeechAudioBufferRecognitionRequest?

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

  func startLive(locale: Locale = .current) async throws {
    try await requestPermissions()

    await stopLive()

    guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
      throw LiveTranscriptionError.recognizerUnavailable
    }

    let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
    recognitionRequest.shouldReportPartialResults = true

    liveRecognitionRequest = recognitionRequest

    let inputNode = audioEngine.inputNode
    let inputFormat = inputNode.outputFormat(forBus: 0)

    inputNode.removeTap(onBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
      self?.liveRecognitionRequest?.append(buffer)
    }

    liveRecognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
      guard let self else { return }

      if let result {
        let text = result.bestTranscription.formattedString
        if result.isFinal {
          self.dispatchToMain {
            self.onFinalText?(text)
          }
        } else {
          self.dispatchToMain {
            self.onVolatileText?(text)
          }
        }
      }

      if let error {
        self.dispatchToMain {
          self.onError?("실시간 전사 오류: \(error.localizedDescription)")
        }
      }
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
    if audioEngine.isRunning {
      audioEngine.inputNode.removeTap(onBus: 0)
      audioEngine.stop()
    }

    liveRecognitionRequest?.endAudio()
    liveRecognitionTask?.cancel()
    liveRecognitionRequest = nil
    liveRecognitionTask = nil

    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  func transcribeFile(url: URL, locale: Locale = .current) async throws -> String {
    try await requestPermissions()

    guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
      throw LiveTranscriptionError.recognizerUnavailable
    }

    let request = SFSpeechURLRecognitionRequest(url: url)
    request.shouldReportPartialResults = true

    return try await withCheckedThrowingContinuation { continuation in
      var hasResumed = false
      var lastText = ""
      var recognitionTask: SFSpeechRecognitionTask?

      recognitionTask = recognizer.recognitionTask(with: request) { result, error in
        if let result {
          lastText = result.bestTranscription.formattedString
          if result.isFinal, !hasResumed {
            hasResumed = true
            recognitionTask?.cancel()
            continuation.resume(returning: lastText)
          }
        }

        if let error, !hasResumed {
          hasResumed = true
          recognitionTask?.cancel()
          continuation.resume(throwing: error)
        }
      }

      if recognitionTask == nil, !hasResumed {
        hasResumed = true
        continuation.resume(throwing: LiveTranscriptionError.noTranscript)
      }
    }
  }

  private func dispatchToMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread {
      block()
    } else {
      DispatchQueue.main.async(execute: block)
    }
  }
}
