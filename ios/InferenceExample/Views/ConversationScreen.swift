// Copyright 2024 The Mediapipe Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import LaTeXSwiftUI
import SwiftUI
import Foundation
import Combine
import GCDWebServer
import Darwin   // getifaddrs, AF_INET, etc.

struct ConversationScreen: View {
  private struct Constants {
    static let alertBackgroundColor = Color.black.opacity(0.3)
    static let modelInitializationAlertText = "Model initialization in progress."
  }

  @Environment(\.dismiss) var dismiss

  @ObservedObject
  var viewModel: ConversationViewModel

  @StateObject
  private var server = LocalLlmServer()

  var body: some View {
    ZStack {
      VStack(spacing: 16) {
        VStack(spacing: 8) {
          Text("Local LLM Server")
            .font(.title2)
            .bold()

          Text("Model: \(viewModel.modelCategory.name)")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 32)

        Group {
          if viewModel.downloadRequired {
            Text("모델 파일이 아직 다운로드되지 않았습니다.\n아래 시트를 통해 모델을 먼저 받아야 합니다.")
              .font(.footnote)
              .multilineTextAlignment(.center)
              .padding()
          } else if viewModel.currentState == .loadingModel {
            VStack(spacing: 12) {
              ProgressView("Model initialization in progress...")
                .tint(Metadata.globalColor)
              Text("모델을 초기화하는 중입니다. 잠시만 기다려 주세요.")
                .font(.footnote)
                .multilineTextAlignment(.center)
            }
            .padding()
          } else if server.isRunning {
            VStack(spacing: 12) {
              Text("서버가 실행 중입니다.")
                .font(.headline)

              VStack(alignment: .leading, spacing: 8) {
                if server.ipAddress == "Unknown" {
                  Text(
                    """
                    현재 아이폰의 IP 주소를 확인할 수 없습니다.
                    Wi-Fi에 연결되어 있는지 확인해 주세요.
                    """
                  )
                  .font(.footnote)
                } else {
                  Text("현재 아이폰 IP 주소: \(server.ipAddress)")
                    .font(.footnote)
                    .bold()
                }

                Text(
                  """
                  같은 네트워크의 다른 기기에서:

                  • URL:  http://\(server.ipAddress):8080/generate
                  • Method:  POST
                  • Body (JSON): { "prompt": "Hello" }
                  
                  로 요청을 보내면, LLM이 응답을
                  스트리밍 (Server-Sent Events)으로 생성합니다.
                  """
                )
                .font(.footnote)
                .multilineTextAlignment(.leading)
              }
            }
            .padding()
          } else if viewModel.currentState == .done {
            Text("모델 초기화는 완료되었지만, 서버가 아직 시작되지 않았습니다.")
              .font(.footnote)
              .multilineTextAlignment(.center)
              .padding()
          } else {
            Text("모델 상태를 준비하는 중입니다…")
              .font(.footnote)
              .multilineTextAlignment(.center)
              .padding()
          }
        }

        Spacer()
      }
      .navigationTitle("Server for \(viewModel.modelCategory.name)")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(Metadata.globalColor, for: .navigationBar)
      .toolbarBackground(.visible, for: .navigationBar)
      .toolbarColorScheme(.dark, for: .navigationBar)
      .disabled(viewModel.shouldDisableClicks())

      if viewModel.currentState == .loadingModel {
        Constants.alertBackgroundColor
          .edgesIgnoringSafeArea(.all)
        ProgressView(Constants.modelInitializationAlertText)
          .tint(Metadata.globalColor)
      }
    }
    .safeAreaInset(edge: .top) {
      if viewModel.remainingSizeInTokens != -1 {
        ModelAccessoryView(
          modelName: viewModel.modelCategory.name,
          remainingTokenCount: $viewModel.remainingSizeInTokens
        )
      }
    }
    .alert(
      error: viewModel.currentState.inferenceError,
      action: { [weak viewModel] in
        if shouldDismiss() {
          dismiss()
        } else {
          viewModel?.resetStateAfterErrorIntimation()
        }
      }
    )
    .sheet(
      isPresented: $viewModel.downloadRequired, onDismiss: didDismissDownloadSheet,
      content: {
        HuggingFaceFlowScreen(
          viewModel: HuggingFaceFlowViewModel(modelCategory: self.viewModel.modelCategory)
        )
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
      }
    )
    .onAppear { [weak viewModel] in
      viewModel?.loadModel()
    }
    .onDisappear { [weak viewModel] in
      viewModel?.clearModel()
      server.stop()
    }
    .onChange(of: viewModel.currentState) { _, newState in
      if newState == .done && !server.isRunning {
        server.start(with: viewModel)
      }
    }
  }

  func didDismissDownloadSheet() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      viewModel.handleModelDownloadedCompleted()
    }
  }

  private func shouldDismiss() -> Bool {
    if case .criticalError = viewModel.currentState { return true }
    return false
  }
}

/// View that displays a message.
struct MessageView: View {
  private struct Constants {
    static let textMessagePadding: CGFloat = 10.0
    static let foregroundColor = Color(red: 0.0, green: 0.0, blue: 0.0)
    static let systemMessageBackgroundColor = Color("SystemColor")
    static let userMessageBackgroundColor = Color("UserColor")
    static let thinkingMessageBackgroundColor = Color("ThinkingColor")
    static let errorBackgroundColor = Color.red.opacity(0.1)
    static let messageBackgroundCornerRadius: CGFloat = 16.0
    static let generationErrorText = "Could not generate response"
    static let font = Font.system(size: 10, weight: .regular, design: .default)
    static let tint = Metadata.globalColor
  }

  @ObservedObject var messageViewModel: MessageViewModel
  var onTextUpdate: (String) -> Void

  var body: some View {
    HStack {
      if messageViewModel.chatMessage.participant == .user {
        Spacer()
      }
      VStack(alignment: messageViewModel.chatMessage.participant == .user ? .trailing : .leading) {
        Text(messageViewModel.chatMessage.title)
          .font(Constants.font)
          .frame(
            alignment: messageViewModel.chatMessage.participant == .user ? .trailing : .leading)
        switch messageViewModel.chatMessage.participant {
        case .user:
          MessageContentView(
            text: messageViewModel.chatMessage.text,
            backgroundColor: Constants.userMessageBackgroundColor)
        case .system(value: .response):
          if messageViewModel.chatMessage.isLoading {
            ProgressView().tint(Constants.tint)
          } else {
            MessageContentView(
              text: messageViewModel.chatMessage.text,
              backgroundColor: Constants.systemMessageBackgroundColor)
          }
        case .system(value: .thinking):
          if messageViewModel.chatMessage.isLoading {
            ProgressView().tint(Constants.tint)
          } else {
            MessageContentView(
              text: messageViewModel.chatMessage.text,
              backgroundColor: Constants.thinkingMessageBackgroundColor)
          }
        case .system(value: .error):
          MessageContentView(
            text: Constants.generationErrorText, backgroundColor: Constants.errorBackgroundColor)
        }
      }
    }
    .listRowSeparator(.hidden)
    .id(messageViewModel.chatMessage.id)
    .onReceive(messageViewModel.$chatMessage) { [weak messageViewModel] _ in
      guard let chatMessageId = messageViewModel?.chatMessage.id else {
        return
      }
      onTextUpdate(chatMessageId)
    }
  }
}

/// Content of a message view which applies attributed string and LaTex modifications for display.
struct MessageContentView: View {
  private struct Constants {
    static let textMessagePadding: CGFloat = 10.0
    static let foregroundColor = Color(red: 0.0, green: 0.0, blue: 0.0)
    static let messageBackgroundCornerRadius: CGFloat = 16.0
  }

  var text: String
  var backgroundColor: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 0.0) {
      ForEach(text.mathTextSplits, id: \.id) { item in
        if item.isMath {
          LaTeX(item.content).parsingMode(.onlyEquations)
        } else {
          Text(item.content.attributedString)
        }
      }
    }
    .padding(Constants.textMessagePadding)
    .foregroundStyle(Constants.foregroundColor)
    .background(
      backgroundColor
    )
    .clipShape(RoundedRectangle(cornerRadius: Constants.messageBackgroundCornerRadius))
  }

}

/// Bottom view that displays text field and button.
struct TextTypingView: View {
  private struct Constants {
    static let messageFieldPlaceHolder = "Message..."
    static let textFieldCornerRadius = 16.0
    static let textFieldHeight = 55.0
    static let textFieldBackgroundColor = Color.white
    static let buttonSize = 30.0
    static let viewBackgroundColor = Color.gray.opacity(0.1)
    static let textFieldStrokeColor = Color.gray
    static let sendButtonImage = "arrow.up.circle.fill"
    static let buttonDisabledColor = Color.gray
    static let buttonEnabledColor = Metadata.globalColor
    static let padding = 10.0
  }

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.colorScheme) var colorScheme
  @Binding var state: ConversationViewModel.State

  var onSubmitAction: (String) -> Void
  var onChangeOfTextAction: (String) -> Void

  @State private var content: String = ""

  enum FocusedField: Hashable {
    case message
  }
  private var backgroundColor: Color {
    colorScheme == .dark ? Color(.systemGray6) : Color(.systemGray5)
  }

  private var textColor: Color {
    colorScheme == .dark ? .white : .black
  }

  @FocusState
  var focusedField: FocusedField?

  var body: some View {
    HStack(spacing: Constants.padding) {
      TextField(Constants.messageFieldPlaceHolder, text: $content)
        .padding()
        .background(backgroundColor)
        .foregroundStyle(textColor)
        .frame(height: Constants.textFieldHeight)
        .textFieldStyle(PlainTextFieldStyle())
        .clipShape(RoundedRectangle(cornerRadius: Constants.textFieldCornerRadius))
        .overlay(
          RoundedRectangle(cornerRadius: Constants.textFieldCornerRadius).stroke(
            Constants.textFieldStrokeColor)
        )
        .focused($focusedField, equals: .message)
        .onSubmit {
          focusedField = nil
        }
        .submitLabel(.return)
        .onChange(of: state) { _, newValue in
          focusedField = newValue == .done ? .message : nil
        }
        .onChange(of: content) { _, newValue in
          /// Only trigger updates when the VM is not generating response.
          /// Specifically to handle the case when the content is set to "" after prompt is submitted for inference.
          /// Recomputation should only happen from the VM during response generation.
          guard state == .done else {
            return
          }
          onChangeOfTextAction(newValue)
        }
        .padding([.leading, .top], Constants.padding)
      Button(action: sendMessage) {
        Image(systemName: Constants.sendButtonImage)
          .resizable()
          .scaledToFit()
          .frame(width: Constants.buttonSize, height: Constants.buttonSize)
          .foregroundColor(isEnabled ? Constants.buttonEnabledColor : Constants.buttonDisabledColor)
      }
      .padding([.trailing, .top], Constants.padding)
    }
    .background(Constants.viewBackgroundColor)
  }

  private func sendMessage() {
    guard !content.isEmpty else {
      return
    }
    let prompt = content
    onSubmitAction(prompt)
    content = ""
  }
}

/// View that displays token count information and refresh session button.
struct ModelAccessoryView: View {
  private struct Constants {
    static let refreshIcon = "arrow.triangle.2.circlepath"
    static let backgroundColor = Color(uiColor: .systemGroupedBackground)
    static let font = Font.system(size: 14.0)
  }

  let modelName: String

  @Binding var remainingTokenCount: Int

  private var tokenCountString: String {
    if remainingTokenCount == -1 {
      return ""
    }

    return "\(remainingTokenCount) tokens remaining."
      + (remainingTokenCount == 0 ? "Please refresh the session." : "")
  }

  var body: some View {
    HStack {
      Spacer()
      Text(tokenCountString)
        .font(Constants.font)
      Spacer()
        .tint(Metadata.globalColor)
    }
    .padding()
    .background(Constants.backgroundColor)
    .buttonStyle(.bordered)
    .controlSize(.mini)
  }
}

extension View {
  /// Displays error alert based on the value of the binding error. This function is invoked when the value of the binding error changes.
  /// - Parameters:
  ///   - error: Binding error based on which the alert is displayed.
  /// - Returns: The error alert.
  func alert<E: LocalizedError>(
    error: E?, buttonTitle: String = "OK",
    action: @escaping () -> Void
  ) -> some View {

    return alert(isPresented: .constant(error != nil), error: error) { _ in
      Button(buttonTitle) {
        action()
      }
    } message: { error in
      Text(error.failureReason ?? "Some error occured")
    }
  }
}

/// ConversationViewModel을 이용해서 /generate 엔드포인트를 제공하는 로컬 HTTP 서버
final class LocalLlmServer: ObservableObject {

  /// 비동기 PUSH 스트림(AsyncStream)을 동기 PULL API(streamBlock)에 연결하기 위한 스레드 안전 큐
  private final class DataQueue {
    private var buffer = [Data]()
    private let lock = NSCondition()
    private var isFinished = false
    private var streamError: Error?

    /// [Producer] (Async Task)
    /// 비동기 스트림에서 받은 데이터 청크를 버퍼에 추가하고 대기 중인 Consumer(streamBlock)에 신호를 보냅니다.
    func push(_ data: Data) {
      lock.lock()
      defer { lock.unlock() }
      guard !isFinished else { return } // 이미 종료되었으면 더 이상 데이터를 받지 않음

      buffer.append(data)
      lock.signal() // 대기 중인 pull() 메서드를 깨움
    }

    /// [Producer] (Async Task)
    /// 스트림이 종료되었음을 알리고, 에러가 있다면 저장한 뒤 대기 중인 Consumer(streamBlock)에 신호를 보냅니다.
    func finish(error: Error? = nil) {
      lock.lock()
      defer { lock.unlock() }
      guard !isFinished else { return } // 중복 finish 방지

      isFinished = true
      streamError = error
      lock.signal() // 대기 중인 pull() 메서드를 깨움
    }

    /// [Consumer] (GCDWebServer Thread - streamBlock)
    /// 다음 데이터 청크를 동기적으로 가져옵니다.
    /// - 데이터가 있으면: 즉시 반환합니다.
    /// - 데이터가 없지만 스트림이 끝나지 않았으면: push() 또는 finish()가 호출될 때까지 스레드를 대기시킵니다.
    /// - 스트림이 종료되었으면: nil을 반환하여 EOF(End-Of-File)를 알립니다.
    /// - 스트림이 오류로 종료되었으면: Error를 throw합니다.
    func pull() throws -> Data? {
      lock.lock()
      defer { lock.unlock() }

      // 버퍼가 비어있고 스트림이 아직 끝나지 않았으면, 신호가 올 때까지 대기
      while buffer.isEmpty && !isFinished {
        lock.wait() // NSCondition.wait()는 lock을 원자적으로 풀고, 신호를 받으면 다시 lock을 잡음
      }

      // 대기에서 깨어남 (데이터가 push되었거나, 스트림이 finish되었음)

      // 1. 에러가 발생하며 종료된 경우
      if let error = streamError {
        throw error
      }

      // 2. 데이터가 버퍼에 있는 경우 (정상 데이터 반환)
      if !buffer.isEmpty {
        return buffer.removeFirst()
      }

      // 3. 버퍼가 비어있고, isFinished가 true이며, 에러가 없는 경우 (정상 종료)
      //    (buffer.isEmpty && isFinished && streamError == nil)
      return nil // EOF
    }
  }

  private let webServer = GCDWebServer()

  @Published
  private(set) var isRunning: Bool = false

  @Published
  var ipAddress: String = "Unknown"

  private weak var viewModel: ConversationViewModel?

  func start(with viewModel: ConversationViewModel) {
    guard !isRunning else { return }

    self.viewModel = viewModel
    let jsonEncoder = JSONEncoder()

    // POST /generate (Streaming)
    // *** FIX: Use the synchronous 'processor' overload that returns a response object ***
    webServer.addHandler(
      forMethod: "POST",
      path: "/generate",
      request: GCDWebServerDataRequest.self
    ) { [weak self] request in
      // 1. viewModel 및 요청 유효성 검사
      guard
        let self,
        let vm = self.viewModel
      else {
        let response = GCDWebServerDataResponse(
          jsonObject: ["error": "Server internal error: ViewModel not found."]
        )!
        response.statusCode = 500
        return response // Return sync
      }

      guard
        let dataRequest = request as? GCDWebServerDataRequest,
        let json = dataRequest.jsonObject as? [String: Any],
        let prompt = json["prompt"] as? String
      else {
        let response = GCDWebServerDataResponse(
          jsonObject: ["error": "Invalid request. Expected JSON {\"prompt\": \"...\"}."]
        )!
        response.statusCode = 400
        return response // Return sync
      }

      // 2. 비동기-동기 브릿지 큐 생성
      let dataQueue = DataQueue()

      // 3. 백그라운드 Task를 시작하여 비동기 스트림의 데이터를 큐에 PUSH
      Task {
        do {
          let responseStream = try await vm.generateStreamStateless(prompt)

          // [Producer]
          for try await partialText in responseStream {
            guard !partialText.isEmpty else { continue }

            let chunkPayload = ["output": partialText]
            let jsonData = try jsonEncoder.encode(chunkPayload)
            let jsonString = String(data: jsonData, encoding: .utf8)!
            let sseMessage = "data: \(jsonString)\n\n"

            dataQueue.push(sseMessage.data(using: .utf8)!)
          }

          // 스트림 정상 종료
          let donePayload = ["output": ""]
          let jsonData = try jsonEncoder.encode(donePayload)
          let jsonString = String(data: jsonData, encoding: .utf8)!
          let doneMessage = "event: done\ndata: \(jsonString)\n\n"
          dataQueue.push(doneMessage.data(using: .utf8)!)

          dataQueue.finish()

        } catch {
          // 스트림 오류 종료
          let errorPayload = ["error": error.localizedDescription]
          if let jsonData = try? jsonEncoder.encode(errorPayload),
            let jsonString = String(data: jsonData, encoding: .utf8)
          {
            let sseMessage = "event: error\ndata: \(jsonString)\n\n"
            dataQueue.push(sseMessage.data(using: .utf8)!)
          }
          dataQueue.finish(error: error)
        }
      }

      // 4. 스트리밍 응답 객체를 *동기적으로* 생성 및 반환
      // *** FIX: 'streamBlock' 이니셜라이저 사용 ***
      let response = GCDWebServerStreamedResponse(
        contentType: "text/event-stream",
        streamBlock: { errorPtr in
          // [Consumer]
          // 이 블록은 GCDWebServer 스레드에서 동기적으로 호출됨
          do {
            // 큐에서 데이터를 PULL (데이터가 없으면 대기)
            // pull()이 nil을 반환하면 스트림이 정상 종료된 것임
            return try dataQueue.pull()
          } catch {
            // pull()이 에러를 throw하면 스트림이 비정상 종료된 것임
            // errorPtr를 통해 GCDWebServer에 에러를 전달
            errorPtr?.pointee = error as NSError
            return nil
          }
        }
      )

      response.setValue("no-cache", forAdditionalHeader: "Cache-Control")
      response.setValue("keep-alive", forAdditionalHeader: "Connection")

      return response // Return sync
    }

    webServer.start(withPort: 8080, bonjourName: nil)

    // 서버 시작 후 현재 Wi-Fi IP 조회
    let ip = getWiFiAddress() ?? "Unknown"
    DispatchQueue.main.async {
      self.ipAddress = ip
    }

    isRunning = true
    print("🌐 Local LLM HTTP server (streaming) started at http://\(ipAddress):8080")
  }

  func stop() {
    guard isRunning else { return }
    webServer.stop()
    isRunning = false
    print("🛑 Local LLM HTTP server stopped")
  }

  /// 현재 기기의 Wi-Fi 인터페이스(en0)의 IPv4/IPv6 주소를 반환
  private func getWiFiAddress() -> String? {
    var address: String?

    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    if getifaddrs(&ifaddr) == 0 {
      var ptr = ifaddr
      while ptr != nil {
        let interface = ptr!.pointee
        let addrFamily = interface.ifa_addr.pointee.sa_family

        if addrFamily == UInt8(AF_INET) || addrFamily == UInt8(AF_INET6) {
          let name = String(cString: interface.ifa_name)
          if name == "en0" { // Wi-Fi 인터페이스
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(
              interface.ifa_addr,
              socklen_t(interface.ifa_addr.pointee.sa_len),
              &hostname,
              socklen_t(hostname.count),
              nil,
              0,
              NI_NUMERICHOST
            )
            address = String(cString: hostname)
          }
        }

        ptr = interface.ifa_next
      }
      freeifaddrs(ifaddr)
    }

    return address
  }
}