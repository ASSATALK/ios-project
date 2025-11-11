import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    static let shared = AppDelegate()

    private let server = HttpLLMServer()
    private let port: UInt16 = 5000

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {

        do {
            try server.start(port: port)
            print("== LLM HTTP server started on :\(port) ==")
        } catch {
            print("!! Failed to start server:", error)
        }
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        server.stop()
    }
}
