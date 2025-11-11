
import Foundation
#if canImport(MLCSwift)
import MLCSwift
#endif

actor MLCManager {
    static let shared = MLCManager()

    func generate(_ request: MLCBridge.GenerationRequest) async throws -> MLCBridge.GenerationResult {
        #if canImport(MLCSwift)
        let (engine, model) = try await prepareEngine()

        let chatMessages = request.messages.map { message in
            ChatCompletionMessage(role: message.role.chatRole, content: message.content)
        }

        var aggregated = ""
        var finishReason: String?
        var usage: MLCBridge.GenerationResult.Usage?

        let stream = await engine.chat.completions.create(
            messages: chatMessages,
            frequency_penalty: request.frequencyPenalty.map(Float.init),
            presence_penalty: request.presencePenalty.map(Float.init),
            max_tokens: request.maxTokens,
            stop: request.stop,
            stream_options: StreamOptions(include_usage: true),
            temperature: request.temperature.map(Float.init),
            top_p: request.topP.map(Float.init)
        )

        for await chunk in stream {
            if let delta = chunk.choices.first?.delta.content {
                aggregated += delta.asText()
            }
            if let reason = chunk.choices.first?.finish_reason {
                finishReason = reason
            }
            if let chunkUsage = chunk.usage {
                usage = .init(chunkUsage)
            }
        }

        return MLCBridge.GenerationResult(
            text: aggregated,
            model: model.id,
            finishReason: finishReason,
            usage: usage
        )
        #else
        throw MLCBridge.BridgeError(message: "MLCSwift framework is not available in this build.")
        #endif
    }

    func preload() async throws {
        #if canImport(MLCSwift)
        _ = try await prepareEngine()
        #else
        throw MLCBridge.BridgeError(message: "MLCSwift framework is not available in this build.")
        #endif
    }

    #if canImport(MLCSwift)
    private struct PackagedModel: Equatable {
        let id: String
        let lib: String
        let path: URL
    }

    private var engine: MLCEngine?
    private var loadedModel: PackagedModel?
    private var warmedModelID: String?
    private let decoder = JSONDecoder()

    private func prepareEngine() async throws -> (engine: MLCEngine, model: PackagedModel) {
        let model = try loadPackagedModel()
        if let engine, let loadedModel, loadedModel == model {
            if warmedModelID != loadedModel.id {
                await warmUp(engine: engine)
                warmedModelID = loadedModel.id
            }
            return (engine, loadedModel)
        }

        let engine = self.engine ?? MLCEngine()
        if let existing = loadedModel, existing != model {
            await engine.unload()
        }

        print("[MLCBridge] loading model: \(model.id)")
        await engine.reload(modelPath: model.path.path, modelLib: model.lib)
        await warmUp(engine: engine)
        print("[MLCBridge] model ready: \(model.id)")

        self.engine = engine
        self.loadedModel = model
        self.warmedModelID = model.id
        return (engine, model)
    }

    private func warmUp(engine: MLCEngine) async {
        for await _ in await engine.chat.completions.create(
            messages: [ChatCompletionMessage(role: .user, content: "")],
            max_tokens: 1
        ) {
            break
        }
        print("[MLCBridge] warm-up finished")
    }

    private func loadPackagedModel() throws -> PackagedModel {
        let fileManager = FileManager.default
        let bundleBaseURL = Bundle.main.bundleURL
        let bundleURL = bundleBaseURL.appendingPathComponent("bundle", isDirectory: true)
        guard fileManager.fileExists(atPath: bundleURL.path) else {
            throw MLCBridge.BridgeError(message: "bundle/ 디렉터리가 앱 번들에 없습니다.")
        }

        let appConfigURL = bundleURL.appendingPathComponent("mlc-app-config.json")
        let data = try Data(contentsOf: appConfigURL)
        let config = try decoder.decode(PackagedAppConfig.self, from: data)

        guard let firstModel = config.modelList.first else {
            throw MLCBridge.BridgeError(message: "mlc-app-config.json에 model_list 항목이 비어 있습니다.")
        }

        guard !firstModel.modelID.isEmpty else {
            throw MLCBridge.BridgeError(message: "mlc-app-config.json의 model_id가 비어 있습니다.")
        }

        guard !firstModel.modelLib.isEmpty else {
            throw MLCBridge.BridgeError(message: "mlc-app-config.json의 model_lib이 비어 있습니다.")
        }

        let relativePath = firstModel.modelPath ?? firstModel.modelID
        let modelURL = bundleURL.appendingPathComponent(relativePath, isDirectory: true)
        guard fileManager.fileExists(atPath: modelURL.path) else {
            throw MLCBridge.BridgeError(
                message: "모델 디렉터리(\(relativePath))를 bundle/에서 찾을 수 없습니다."
            )
        }

        return PackagedModel(id: firstModel.modelID, lib: firstModel.modelLib, path: modelURL)
    }
    #endif
}

enum MLCBridge {
    struct BridgeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    enum MessageRole: String, Codable {
        case system
        case user
        case assistant
        case tool
    }

    struct Message: Codable {
        var role: MessageRole
        var content: String
    }

    struct GenerationRequest: Codable {
        var messages: [Message]
        var maxTokens: Int?
        var temperature: Double?
        var topP: Double?
        var stop: [String]?
        var presencePenalty: Double?
        var frequencyPenalty: Double?

        init(messages: [Message],
             maxTokens: Int? = nil,
             temperature: Double? = nil,
             topP: Double? = nil,
             stop: [String]? = nil,
             presencePenalty: Double? = nil,
             frequencyPenalty: Double? = nil) {
            self.messages = messages
            self.maxTokens = maxTokens
            self.temperature = temperature
            self.topP = topP
            self.stop = stop
            self.presencePenalty = presencePenalty
            self.frequencyPenalty = frequencyPenalty
        }
    }

    struct GenerationResult: Codable {
        struct Usage: Codable {
            struct Extra: Codable {
                var prefillTokensPerSecond: Double?
                var decodeTokensPerSecond: Double?
                var numPrefillTokens: Int?

                init(prefillTokensPerSecond: Double?,
                     decodeTokensPerSecond: Double?,
                     numPrefillTokens: Int?) {
                    self.prefillTokensPerSecond = prefillTokensPerSecond
                    self.decodeTokensPerSecond = decodeTokensPerSecond
                    self.numPrefillTokens = numPrefillTokens
                }
            }

            var promptTokens: Int
            var completionTokens: Int
            var totalTokens: Int
            var extra: Extra?

            init(promptTokens: Int, completionTokens: Int, totalTokens: Int, extra: Extra?) {
                self.promptTokens = promptTokens
                self.completionTokens = completionTokens
                self.totalTokens = totalTokens
                self.extra = extra
            }
        }

        var text: String
        var model: String?
        var finishReason: String?
        var usage: Usage?
    }

    static func generate(request: GenerationRequest,
                         completion: @escaping (Result<GenerationResult, Error>) -> Void) {
        Task {
            do {
                let result = try await MLCManager.shared.generate(request)
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
        }
    }

    static func preload() {
        Task {
            do {
                try await MLCManager.shared.preload()
            } catch {
                print("[MLCBridge] preload failed: \(error)")
            }
        }
    }
}

#if canImport(MLCSwift)
private extension MLCBridge.MessageRole {
    var chatRole: ChatCompletionRole {
        switch self {
        case .system: return .system
        case .user: return .user
        case .assistant: return .assistant
        case .tool: return .tool
        }
    }
}

private extension MLCBridge.GenerationResult.Usage {
    init(_ usage: CompletionUsage) {
        let extra = usage.extra.map {
            MLCBridge.GenerationResult.Usage.Extra(
                prefillTokensPerSecond: $0.prefill_tokens_per_s.map(Double.init),
                decodeTokensPerSecond: $0.decode_tokens_per_s.map(Double.init),
                numPrefillTokens: $0.num_prefill_tokens
            )
        }
        self.init(
            promptTokens: usage.prompt_tokens,
            completionTokens: usage.completion_tokens,
            totalTokens: usage.total_tokens,
            extra: extra
        )
    }
}

private struct PackagedAppConfig: Decodable {
    struct ModelRecord: Decodable {
        var modelPath: String?
        var modelLib: String
        var modelID: String

        enum CodingKeys: String, CodingKey {
            case modelPath = "model_path"
            case modelLib = "model_lib"
            case modelID = "model_id"
        }
    }

    var modelList: [ModelRecord]

    enum CodingKeys: String, CodingKey {
        case modelList = "model_list"
    }
}
#endif
