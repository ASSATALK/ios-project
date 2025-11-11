import SwiftUI

struct ContentView: View {
    @State private var ip: String = IPHelper.localIPv4() ?? "0.0.0.0"

    var body: some View {
        VStack(spacing: 12) {
            Text("MLC LLM Local Server")
                .font(.title.bold())
            Text("접속 주소")
                .font(.headline)
            Text("http://\(ip):5000")
                .font(.system(.title3, design: .monospaced))
                .padding(.bottom, 8)
            Text("엔드포인트")
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("GET  /health")
                Text("POST /api/generate   (JSON: {\"prompt\": \"...\"})")
                Text("POST /api/chat       (JSON: Chat 포맷, 임시 동일 처리)")
            }
            .font(.system(.subheadline, design: .monospaced))
            .padding(.horizontal)

            Spacer()
            Text("앱이 포그라운드일 때 서버가 동작합니다.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            ip = IPHelper.localIPv4() ?? "0.0.0.0"
        }
    }
}
