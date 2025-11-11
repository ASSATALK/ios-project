
import Foundation
import Network

final class HttpLLMServer {
    private var listener: NWListener!

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
                var prompt = ""
                if let bodyData = bodyStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                    prompt = (json["prompt"] as? String) ?? ""
                }
                print("[Generate] prompt length:", prompt.count)
                MLCBridge.generate(prompt: prompt) { result in
                    let json: [String: Any] = ["text": result]
                    let respBody = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
                    let resp = self.makeResponse(status: 200, contentType: "application/json", body: respBody, cors: true)
                    conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
                }
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
