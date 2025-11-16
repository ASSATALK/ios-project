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

              Text(
                """
                같은 네트워크의 다른 기기에서:

                • URL:  http://<아이폰 IP 주소>:8080/generate
                • Method:  POST
                • Body (JSON): { "prompt": "Hello" }

                로 요청을 보내면, LLM이 응답을 생성합니다.
                """
              )
              .font(.footnote)
              .multilineTextAlignment(.leading)
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

  private let webServer = GCDWebServer()

  @Published
  private(set) var isRunning: Bool = false

  private weak var viewModel: ConversationViewModel?

  func start(with viewModel: ConversationViewModel) {
    guard !isRunning else { return }

    self.viewModel = viewModel

    // POST /generate
    webServer.addHandler(
      forMethod: "POST",
      path: "/generate",
      request: GCDWebServerDataRequest.self
    ) { [weak self] request in
      guard
        let self,
        let vm = self.viewModel,
        let dataRequest = request as? GCDWebServerDataRequest,
        let json = dataRequest.jsonObject as? [String: Any],
        let prompt = json["prompt"] as? String
      else {
        let response = GCDWebServerDataResponse(
          jsonObject: ["error": "Invalid request. Expected JSON {\"prompt\": \"...\"}."]
        )!
        response.statusCode = 400
        return response
      }

      let result = self.generateBlocking(prompt: prompt, with: vm)

      switch result {
      case .success(let output):
        let body: [String: Any] = [
          "prompt": prompt,
          "output": output,
        ]
        return GCDWebServerDataResponse(jsonObject: body)!   // ← 여기도 ! 추가

      case .failure(let error):
        let response = GCDWebServerDataResponse(
          jsonObject: ["error": "\(error)"]
        )!
        response.statusCode = 500
        return response
      }
    }


    webServer.start(withPort: 8080, bonjourName: nil)
    isRunning = true
    print("🌐 Local LLM HTTP server started on port 8080")
  }

  func stop() {
    guard isRunning else { return }
    webServer.stop()
    isRunning = false
    print("🛑 Local LLM HTTP server stopped")
  }

  /// GCDWebServer 핸들러는 동기이기 때문에, 내부에서 async → sync 브릿지를 만든다.
  private func generateBlocking(
    prompt: String,
    with viewModel: ConversationViewModel
  ) -> Result<String, Error> {
    var result: Result<String, Error>?
    let semaphore = DispatchSemaphore(value: 0)

    Task {
      do {
        let text = try await viewModel.generateOnceStateless(prompt)
        result = .success(text)
      } catch {
        result = .failure(error)
      }
      semaphore.signal()
    }

    semaphore.wait()

    return result ?? .failure(
      NSError(
        domain: "LocalLlmServer",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "No result from LLM"]
      )
    )
  }
}
