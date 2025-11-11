import Foundation

public struct GenerateRequest: Decodable {
    public let prompt: String
    public let max_tokens: Int?
    public let temperature: Double?
}

public enum MLCBridge {
    // 실제 MLC 연동 경로 (MLCSwift 추가하면 자동 사용)
    #if canImport(MLCSwift)
    public static func isReady() -> Bool { MLCManager.shared.isReady }
    public static func warmupIfNeeded() { MLCManager.shared.warmupIfNeeded() }

    public static func generate(prompt: String,
                                maxTokens: Int = 128,
                                temperature: Double = 0.7,
                                onToken: @escaping (String) -> Void) async throws {
        try await MLCManager.shared.generate(prompt: prompt,
                                             maxTokens: maxTokens,
                                             temperature: temperature,
                                             onToken: onToken)
    }
    #else
    // 안전 모드(MLC 미포함): 모의 스트리밍
    public static func isReady() -> Bool { true }
    public static func warmupIfNeeded() { /* no-op */ }

    public static func generate(prompt: String,
                                maxTokens: Int = 128,
                                temperature: Double = 0.7,
                                onToken: @escaping (String) -> Void) async throws {
        // 간단 NDJSON 토큰 스트리밍 모사
        let fake = "You said: \(prompt.prefix(200))"
        for ch in fake.split(separator: " ") {
            onToken(String(ch))
            try await Task.sleep(nanoseconds: 60_000_000) // 60ms
        }
        onToken("[END]")
    }
    #endif
}
