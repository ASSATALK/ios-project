
import SwiftUI

struct ContentView: View {
    @State private var ip: String = IPHelper.localIPv4() ?? "알수없음"
    let port: Int = 8080
    var body: some View {
        VStack(spacing: 12) {
            Text("MLC Local Server").font(.title2).bold()
            Text("IP: \(ip) :\(port)").font(.headline).monospaced()
            Text("헬스: http://\(ip):\(port)/health").font(.footnote)
            VStack(spacing: 4) {
                Text("POST http://\(ip):\(port)/api/generate")
                Text("{ \"prompt\": \"안녕?\" }")
            }
            .font(.footnote)
            .monospaced()
            Button("IP 새로고침") { ip = IPHelper.localIPv4() ?? "알수없음" }
        }
        .padding()
    }
}
#Preview { ContentView() }
