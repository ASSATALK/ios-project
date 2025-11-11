
# ios-mlc-server (MLC skeleton + in-app HTTP server)

**What this is**
- Minimal iOS app that starts a simple HTTP server (Network.framework) on port 8080.
- `MLCBridge` is a stub (echo). Replace with real MLC-LLM calls later.
- Uses **XcodeGen** in CI to generate the Xcode project from `project.yml`.
- GitHub Actions builds an **unsigned IPA** artifact you can sideload with **Sideloadly**.

**Endpoints**
- `POST /api/generate` with JSON: `{ "prompt": "안녕?" }` → returns `{ "text": "echo: 안녕?" }`

**Local build (optional, if you have macOS)**
```bash
brew install xcodegen
xcodegen generate
open MLCServerApp.xcodeproj
```

**CI build**
- Push this repo to GitHub.
- Run the `build-ios-ipa` workflow.
- Download the artifact `MLCServerApp-unsigned` → `*.ipa`.

**Sideload**
- Use Sideloadly on Windows/macOS with your Apple ID (free: 7-day cert).
