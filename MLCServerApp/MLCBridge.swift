
import Foundation
#if canImport(MLCSwift)
import MLCSwift
#endif

actor MLCManager {
    static let shared = MLCManager()
    #if canImport(MLCSwift)
    private var engine: MLCEngine?
    #endif

    func ensureLoaded() async throws {
        #if canImport(MLCSwift)
        if engine != nil { return }
        let e = MLCEngine()

        guard let bundleURL = Bundle.main.resourceURL?.appendingPathComponent("bundle", isDirectory: true) else {
            throw NSError(domain: "MLC", code: -1, userInfo: [NSLocalizedDescriptionKey: "bundle/ not found"])
        }
        let configURL = bundleURL.appendingPathComponent("mlc-app-config.json")
        var modelLib = "model_iphone"
        if let data = try? Data(contentsOf: configURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let lib = obj["model_lib"] as? String, !lib.isEmpty {
            modelLib = lib
        }

        await e.reload(modelPath: bundleURL.path, modelLib: modelLib)
        self.engine = e
        #else
        #endif
    }

    func generate(_ prompt: String) async throws -> String {
        #if canImport(MLCSwift)
        try await ensureLoaded()
        guard let engine = self.engine else { return "엔진 로드 실패" }

        var out = ""
        for await res in await engine.chat.completions.create(
            messages: [ChatCompletionMessage(role: .user, content: prompt)]
        ) {
            if let delta = res.choices.first?.delta.content?.asText() {
                out += delta
            }
        }
        return out
        #else
        return "echo: " + prompt
        #endif
    }
}

enum MLCBridge {
    static func generate(prompt: String, completion: @escaping (String) -> Void) {
        Task {
            do {
                let txt = try await MLCManager.shared.generate(prompt)
                completion(txt)
            } catch {
                completion("에러: \(error)")
            }
        }
    }
}
