
import Foundation
import Network

final class HttpLLMServer {
    private var listener: NWListener!
    private let requestDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
    private let responseEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    func start(port: UInt16 = 8080) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw NSError(domain: "port", code: -1) }
        listener = try NWListener(using: .tcp, on: nwPort)
        listener.stateUpdateHandler = { print("[NWListener state]", $0) }
        listener.newConnectionHandler = { [weak self] conn in
            print("[Conn] new:", conn.endpoint)
            conn.start(queue: .main)
            self?.handle(conn)
        }
        listener.start(queue: .main)
        print("[Server] listening on port", port)
    }

    private func handle(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty,
                  let req = String(data: data, encoding: .utf8) else { conn.cancel(); return }
            let first = req.split(separator: "\n").first ?? ""
            print("[Request]", first.trimmingCharacters(in: .whitespacesAndNewlines))

            if req.hasPrefix("GET /health") {
                let body = Data("{\"ok\":true}".utf8)
                conn.send(content: self.makeResponse(status: 200, contentType: "application/json", body: body, cors: true),
                          completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            if req.hasPrefix("OPTIONS ") {
                let header = """
                HTTP/1.1 204 No Content\r
                Access-Control-Allow-Origin: *\r
                Access-Control-Allow-Methods: POST, GET, OPTIONS\r
                Access-Control-Allow-Headers: Content-Type\r
                Content-Length: 0\r
                Connection: close\r

                """
                conn.send(content: Data(header.utf8), completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            if req.starts(with: "POST /api/generate") {
                let bodyStr = self.extractBody(from: req)
                self.handleGenerate(body: bodyStr, connection: conn)
                return
            }

            let body = Data("Not Found".utf8)
            let resp = self.makeResponse(status: 404, contentType: "text/plain", body: body, cors: true)
            conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    private func extractBody(from http: String) -> String {
        if let r = http.range(of: "\r\n\r\n") { return String(http[r.upperBound...]) }
        return ""
    }

    private func handleGenerate(body: String, connection: NWConnection) {
        guard let bodyData = body.data(using: .utf8) else {
            sendJSON(ErrorResponse(error: "요청 본문을 디코드할 수 없습니다."), status: 400, connection: connection)
            return
        }

        do {
            let payload = try requestDecoder.decode(GenerateAPIRequest.self, from: bodyData)
            let request = try payload.asBridgeRequest()
            let preview = request.messages.last?.content ?? ""
            print("[Generate] messages: \(request.messages.count) last length: \(preview.count)")

            MLCBridge.generate(request: request) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let generation):
                    self.sendJSON(generation, status: 200, connection: connection)
                case .failure(let error):
                    self.sendJSON(ErrorResponse(error: error.localizedDescription), status: 500, connection: connection)
                }
            }
        } catch {
            let message: String
            if let validationError = error as? GenerateAPIRequest.ValidationError {
                message = validationError.localizedDescription
            } else if let decodingError = error as? DecodingError {
                message = "요청 JSON 형식이 잘못되었습니다: \(decodingError.localizedDescription)"
            } else {
                message = "요청을 처리할 수 없습니다."
            }
            sendJSON(ErrorResponse(error: message), status: 400, connection: connection)
        }
    }

    private func sendJSON<T: Encodable>(_ value: T, status: Int, connection: NWConnection) {
        do {
            let body = try responseEncoder.encode(value)
            let resp = makeResponse(status: status, contentType: "application/json", body: body, cors: true)
            connection.send(content: resp, completion: .contentProcessed { _ in connection.cancel() })
        } catch {
            let fallback = Data("{\"error\":\"응답을 직렬화하지 못했습니다.\"}".utf8)
            let resp = makeResponse(status: 500, contentType: "application/json", body: fallback, cors: true)
            connection.send(content: resp, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func makeResponse(status: Int, contentType: String, body: Data, cors: Bool) -> Data {
        var header = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        if cors { header += "Access-Control-Allow-Origin: *\r\n" }
        header += "Connection: close\r\n\r\n"
        return Data(header.utf8) + body
    }

    private func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 204: return "No Content"
        case 404: return "Not Found"
        default: return "OK"
        }
    }
}

private extension HttpLLMServer {
    struct GenerateAPIRequest: Decodable {
        struct Message: Decodable {
            var role: MLCBridge.MessageRole
            var content: String
        }

        var prompt: String?
        var messages: [Message]?
        var maxTokens: Int?
        var temperature: Double?
        var topP: Double?
        var stop: [String]?
        var presencePenalty: Double?
        var frequencyPenalty: Double?

        func asBridgeRequest() throws -> MLCBridge.GenerationRequest {
            var normalizedMessages: [MLCBridge.Message] = (messages ?? []).map {
                MLCBridge.Message(role: $0.role, content: $0.content)
            }

            if normalizedMessages.isEmpty,
               let prompt,
               !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                normalizedMessages = [MLCBridge.Message(role: .user, content: prompt)]
            }

            normalizedMessages = normalizedMessages.filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !normalizedMessages.isEmpty else { throw ValidationError.emptyPrompt }

            if let maxTokens, maxTokens <= 0 { throw ValidationError.invalidMaxTokens }
            if let temperature, temperature < 0 { throw ValidationError.invalidTemperature }
            if let topP, topP <= 0 || topP > 1 { throw ValidationError.invalidTopP }

            let sanitizedStops = stop?
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            return MLCBridge.GenerationRequest(
                messages: normalizedMessages,
                maxTokens: maxTokens,
                temperature: temperature,
                topP: topP,
                stop: sanitizedStops,
                presencePenalty: presencePenalty,
                frequencyPenalty: frequencyPenalty
            )
        }

        enum ValidationError: LocalizedError {
            case emptyPrompt
            case invalidMaxTokens
            case invalidTemperature
            case invalidTopP

            var errorDescription: String? {
                switch self {
                case .emptyPrompt:
                    return "prompt 또는 messages 중 하나는 최소 한 글자를 포함해야 합니다."
                case .invalidMaxTokens:
                    return "max_tokens 값은 1 이상의 정수여야 합니다."
                case .invalidTemperature:
                    return "temperature 값은 0 이상이어야 합니다."
                case .invalidTopP:
                    return "top_p 값은 0보다 크고 1 이하이어야 합니다."
                }
            }
        }
    }

    struct ErrorResponse: Codable {
        var error: String
    }
}
