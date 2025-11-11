
# ios-mlc-server (MLC skeleton + in-app HTTP server)

**What this is**
- Minimal iOS app that starts a simple HTTP server (Network.framework) on port 8080.
- `MLCBridge` loads the packaged `mlc-app-config.json` and calls MLC-LLM through `MLCSwift`.
- Uses **XcodeGen** in CI to generate the Xcode project from `project.yml`.
- GitHub Actions builds an **unsigned IPA** artifact you can sideload with **Sideloadly**.

**Runtime / API**
- Health probe: `GET /health` → `{ "ok": true }`
- Text generation: `POST /api/generate`

  ```json
  {
    "messages": [
      { "role": "system", "content": "You are a helpful assistant." },
      { "role": "user", "content": "안녕?" }
    ],
    "max_tokens": 128,
    "temperature": 0.2
  }
  ```

  Response (fields omitted when not available):

  ```json
  {
    "text": "안녕하세요! ...",
    "model": "gemma-3-4b-it-q4bf16_1-MLC",
    "finish_reason": "stop",
    "usage": {
      "prompt_tokens": 15,
      "completion_tokens": 42,
      "total_tokens": 57,
      "extra": {
        "prefill_tokens_per_second": 210.3,
        "decode_tokens_per_second": 32.4
      }
    }
  }
  ```

  - `prompt` is still accepted for quick tests: `{ "prompt": "간단 테스트" }`.
  - Invalid payloads receive HTTP 400 with `{ "error": "..." }`.
  - Inference failures surface as HTTP 500 with error strings from the bridge.

**MLC 패키징 준비**

1. Python 3.9+ 환경에서 [MLC-LLM iOS 패키징 가이드](https://mlc.ai/mlc-llm/docs/install/ios.html)를 참고해 `mlc_llm` CLI를 설치합니다. (예: `pip install --pre --extra-index-url https://mlc.ai/wheels mlc-llm-nightly`)
2. `mlc-llm` 소스코드를 내려받고 환경 변수를 지정합니다.

   ```bash
   git clone https://github.com/mlc-ai/mlc-llm.git ../mlc-llm
   export MLC_LLM_SOURCE_DIR="$(pwd)/../mlc-llm"
   ```

3. 이 저장소 루트에서 아래 스크립트를 실행하면 `dist/` 폴더 안에 모델 번들과 라이브러리, `MLCSwift.xcframework`가 내려받아집니다.

```bash
./Scripts/prepare_mlc_assets.sh
```

- 결과물은 `dist/bundle/mlc-app-config.json`과 `dist/bundle/<model_id>/...` 구조를 형성합니다.
- 앱은 `model_list[0]` 항목을 자동으로 읽어 해당 모델을 로드합니다.
- 스크립트는 `cmake_minimum_required` 범위를 3.5…3.27로 확장하고 `prepare_libs.sh`에 `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`를 추가하며
  iOS 번들 빌드에서 충돌을 일으키던 `-lunwind` 플래그를 제거합니다. 따라서 과거 CMake 호환성 오류가 다시 발생하지 않습니다.

**Local build (optional, if you have macOS)**
```bash
brew install xcodegen
xcodegen generate
open MLCServerApp.xcodeproj
```

**CI build**
- Push this repo to GitHub.
- Ensure `dist/`에 패키징된 파일이 포함되도록 [Git LFS](https://git-lfs.com) 또는 별도 아티팩트 저장소를 활용하세요. (저장소에는 기본적으로 비어있는 `.gitignore`만 포함되어 있습니다.)
- Run the `build-ios-ipa` workflow.
- Download the artifact `MLCServerApp-unsigned` → `*.ipa`.

**Sideload**
- Use Sideloadly on Windows/macOS with your Apple ID (free: 7-day cert).
