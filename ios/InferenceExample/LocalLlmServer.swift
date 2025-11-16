import Foundation
import Combine
import GCDWebServer

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
        )
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
        return GCDWebServerDataResponse(jsonObject: body)

      case .failure(let error):
        let response = GCDWebServerDataResponse(
          jsonObject: ["error": "\(error)"]
        )
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
