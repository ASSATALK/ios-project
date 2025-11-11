import Foundation
import Network

final class HttpLLMServer {
    private var listener: NWListener!

    func start(port: UInt16 = 5000) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "HttpLLMServer.port", code: -1)
        }
        listener = try NWListener(using: .tcp, on: nwPort)
        listener.stateUpdateHandler = { print("[NWListener]", $0) }
        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            self?.handle(conn)
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
    }

    private func handle(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, error == nil, let data else {
                conn.cancel()
                return
            }
            let req = String(decoding: data, as: UTF8.self)
            Task {
                await self.respond(conn: conn, raw: req)
            }
            if isComplete == false {
                // keep-alive 미지원: 간단화를 위해 1회 응답 후 닫음
            }
        }
    }

    private func respond(conn: NWConnection, raw: String) async {
        let lines = raw.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else {
            conn.cancel(); return
        }
        let comps = requestLine.split(separator: " ")
        guard comps.count >= 2 else { conn.cancel(); return }

        let method = String(comps[0])
        let path = String(comps[1])

        // 본문 추출
        let sep = "\r\n\r\n"
        let bodyStr: String = {
            if let range = raw.range(of: sep) {
                return String(raw[range.upperBound...])
            }
            return ""
        }()

        switch (method, path) {
        case ("GET", "/health"):
            send(conn, status: 200, contentType: "application/json", body: #"{"ok":true}"#)

        case ("OPTIONS", _):
            // CORS Preflight
            send(conn, status: 204, contentType: "text/plain", body: "", cors: true)

        case ("POST", "/api/generate"), ("POST", "/api/chat"):
            // request JSON 파싱
            let req = parseGenerate(bodyStr) ?? GenerateRequest(prompt: bodyStr, max_tokens: 128, temperature: 0.7)

            // NDJSON 라인들을 메모리에 모아 한 방에 전송(클라이언트는 라인단위 파싱)
            var lines: [String] = []
            await withCheckedContinuation { cont in
                Task {
                    do {
                        try await MLCBridge.generate(prompt: req.prompt,
                                                     maxTokens: req.max_tokens ?? 128,
                                                     temperature: req.temperature ?? 0.7) { token in
                            let obj = ["token": token]
                            if let data = try? JSONSerialization.data(withJSONObject: obj),
                               let line = String(data: data, encoding: .utf8) {
                                lines.append(line)
                            }
                        }
                        cont.resume()
                    } catch {
                        let obj = ["error": "generation_failed", "message": "\(error)"]
                        if let data = try? JSONSerialization.data(withJSONObject: obj),
                           let line = String(data: data, encoding: .utf8) {
                            lines.append(line)
                        }
                        cont.resume()
                    }
                }
            }
            let body = lines.joined(separator: "\n") + "\n"
            send(conn, status: 200, contentType: "application/x-ndjson", body: body, cors: true)

        default:
            send(conn, status: 404, contentType: "text/plain", body: "Not Found")
        }
    }

    private func parseGenerate(_ s: String) -> GenerateRequest? {
        guard let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GenerateRequest.self, from: data)
    }

    private func send(_ conn: NWConnection, status: Int, contentType: String, body: String, cors: Bool = false) {
        var header = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.utf8.count)\r\n"
        if cors {
            header += "Access-Control-Allow-Origin: *\r\n"
            header += "Access-Control-Allow-Methods: POST, GET, OPTIONS\r\n"
            header += "Access-Control-Allow-Headers: Content-Type\r\n"
        }
        header += "Connection: close\r\n\r\n"
        let data = Data(header.utf8) + Data(body.utf8)
        conn.send(content: data, completion: .contentProcessed { _ in
            conn.cancel()
        })
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
