
import UIKit

class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    let server = HttpLLMServer()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        window = UIWindow(frame: UIScreen.main.bounds)
        let vc = UIViewController()
        vc.view.backgroundColor = .systemBackground
        window?.rootViewController = vc
        window?.makeKeyAndVisible()

        do {
            try server.start(port: 8080)
            UIApplication.shared.isIdleTimerDisabled = true
            print("LLM server started on :8080")
            MLCBridge.preload()
        } catch {
            print("Server start failed:", error)
        }
        return true
    }
}
