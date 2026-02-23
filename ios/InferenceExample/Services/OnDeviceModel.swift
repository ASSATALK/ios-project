import AVFoundation
import Foundation
import Speech

final class OnDeviceModel {
  enum LiveTranscriptionError: LocalizedError {
    case unsupportedOS
    case speechPermissionDenied
    case microphonePermissionDenied
    case unavailableAnalyzerFormat
    case invalidAudioInput

    var errorDescription: String? {
      switch self {
      case .unsupportedOS:
        return "SpeechAnalyzer/SpeechTranscriber는 iOS 18 이상에서만 동작합니다."
      case .speechPermissionDenied:
        return "음성 인식 권한이 거부되었습니다."
      case .microphonePermissionDenied:
        return "마이크 권한이 거부되었습니다."
      case .unavailableAnalyzerFormat:
        return "지원 가능한 오디오 포맷을 찾지 못했습니다."
      case .invalidAudioInput:
        return "오디오 입력 버퍼를 변환할 수 없습니다."
      }
    }
  }

  var onVolatileText: ((String) -> Void)?
  var onFinalText: ((String) -> Void)?
  var onError: ((String) -> Void)?

  private let audioEngine = AVAudioEngine()
  private var analyzerTask: Task<Void, Never>?
  private var resultsTask: Task<Void, Never>?
  private var liveRuntime: Any?

  @available(iOS 18.0, *)
  private final class LiveRuntime {
    let analyzer: SpeechAnalyzer
    let transcriber: SpeechTranscriber
    var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    var lastInput: AnalyzerInput?

    init(analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber) {
      self.analyzer = analyzer
      self.transcriber = transcriber
    }
  }

  func requestPermissions() async throws {
    let speechAuth = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status)
      }
    }

    guard speechAuth == .authorized else {
      throw LiveTranscriptionError.speechPermissionDenied
    }

    let micGranted = await withCheckedContinuation { continuation in
      AVAudioSession.sharedInstance().requestRecordPermission { granted in
        continuation.resume(returning: granted)
      }
    }

    guard micGranted else {
      throw LiveTranscriptionError.microphonePermissionDenied
    }
  }

  func startLive(locale: Locale = .current) async throws {
    guard #available(iOS 18.0, *) else {
      throw LiveTranscriptionError.unsupportedOS
    }

    if audioEngine.isRunning {
      await stopLive()
    }

    let liveTranscriber = SpeechTranscriber(
      locale: locale,
      transcriptionOptions: [],
      reportingOptions: [.volatileResults],
      attributeOptions: [.audioTimeRange]
    )

    let liveAnalyzer = SpeechAnalyzer(modules: [liveTranscriber])

    guard let preferredFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
      compatibleWith: [liveTranscriber]
    ) else {
      throw LiveTranscriptionError.unavailableAnalyzerFormat
    }

    let runtime = LiveRuntime(analyzer: liveAnalyzer, transcriber: liveTranscriber)
    liveRuntime = runtime

    let stream = AsyncStream<AnalyzerInput> { continuation in
      runtime.inputContinuation = continuation
    }

    resultsTask = Task { [weak self] in
      guard let self else { return }
      do {
        for try await result in liveTranscriber.results {
          let text = result.text.plainText
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
      } catch {
        self.dispatchToMain {
          self.onError?("전사 결과 스트림 오류: \(error.localizedDescription)")
        }
      }
    }

    analyzerTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await liveAnalyzer.start(inputSequence: stream)
      } catch {
        self.dispatchToMain {
          self.onError?("SpeechAnalyzer 시작 실패: \(error.localizedDescription)")
        }
      }
    }

    do {
      try configureAndStartAudioEngine(targetFormat: preferredFormat)
    } catch {
      await stopLive()
      throw error
    }
  }

  func stopLive() async {
    if audioEngine.isRunning {
      audioEngine.inputNode.removeTap(onBus: 0)
      audioEngine.stop()
    }

    if #available(iOS 18.0, *), let runtime = liveRuntime as? LiveRuntime {
      runtime.inputContinuation?.finish()

      do {
        if let finalInput = runtime.lastInput {
          try await runtime.analyzer.finalizeAndFinish(through: finalInput)
        } else {
          await runtime.analyzer.cancelAndFinishNow()
        }
      } catch {
        dispatchToMain {
          self.onError?("SpeechAnalyzer 종료 실패: \(error.localizedDescription)")
        }
      }
    }

    analyzerTask?.cancel()
    resultsTask?.cancel()
    analyzerTask = nil
    resultsTask = nil
    liveRuntime = nil
  }

  func transcribeFile(url: URL, locale: Locale = .current) async throws -> String {
    guard #available(iOS 18.0, *) else {
      throw LiveTranscriptionError.unsupportedOS
    }

    let fileTranscriber = SpeechTranscriber(
      locale: locale,
      transcriptionOptions: [],
      reportingOptions: [.volatileResults],
      attributeOptions: [.audioTimeRange]
    )

    let fileAnalyzer = SpeechAnalyzer(modules: [fileTranscriber])

    let collectTask = Task<String, Error> {
      var finalized = ""
      for try await result in fileTranscriber.results {
        let text = result.text.plainText
        if result.isFinal {
          if !finalized.isEmpty {
            finalized += "\n"
          }
          finalized += text
        }
      }
      return finalized
    }

    do {
      if let lastFileInput = try await fileAnalyzer.analyzeSequence(from: url) {
        try await fileAnalyzer.finalizeAndFinish(through: lastFileInput)
      } else {
        await fileAnalyzer.cancelAndFinishNow()
      }

      return try await collectTask.value
    } catch {
      collectTask.cancel()
      throw error
    }
  }

  private func configureAndStartAudioEngine(targetFormat: AVAudioFormat) throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
    try session.setActive(true, options: .notifyOthersOnDeactivation)

    let inputNode = audioEngine.inputNode
    let inputFormat = inputNode.outputFormat(forBus: 0)

    inputNode.removeTap(onBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
      self?.consumeIncomingBuffer(buffer, targetFormat: targetFormat)
    }

    audioEngine.prepare()
    try audioEngine.start()
  }

  private func consumeIncomingBuffer(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
    guard #available(iOS 18.0, *), let runtime = liveRuntime as? LiveRuntime else {
      return
    }

    guard let converted = convertBuffer(buffer, to: targetFormat) else {
      dispatchToMain {
        self.onError?(LiveTranscriptionError.invalidAudioInput.localizedDescription)
      }
      return
    }

    let input = AnalyzerInput(buffer: converted)
    runtime.lastInput = input
    runtime.inputContinuation?.yield(input)
  }

  private func convertBuffer(_ source: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
    let sameFormat = source.format.sampleRate == targetFormat.sampleRate
      && source.format.channelCount == targetFormat.channelCount
      && source.format.commonFormat == targetFormat.commonFormat

    if sameFormat {
      return source
    }

    guard let converter = AVAudioConverter(from: source.format, to: targetFormat) else {
      return nil
    }

    let ratio = targetFormat.sampleRate / source.format.sampleRate
    let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 1

    guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
      return nil
    }

    var provided = false
    var conversionError: NSError?

    let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
      if provided {
        outStatus.pointee = .noDataNow
        return nil
      }
      provided = true
      outStatus.pointee = .haveData
      return source
    }

    guard status != .error else {
      return nil
    }

    return output
  }

  private func dispatchToMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread {
      block()
    } else {
      DispatchQueue.main.async(execute: block)
    }
  }
}

private extension AttributedString {
  var plainText: String {
    String(characters)
  }
}
