# InferenceExample (Speech Transcriber)

## What changed
- 기존 LLM/MediaPipe 중심 코드를 제거하고, Speech framework 중심 전사 앱으로 재구성했습니다.
- 타깃/스킴/워크스페이스 명은 그대로 유지했습니다.

## Features
- Real-time transcription via microphone (`SFSpeechRecognizer`)
- Audio file transcription through iOS file picker
- Lightweight SwiftUI UI for live and file transcript views

## CI compatibility note
- GitHub Actions `macos-latest` SDK 호환성을 우선해 `SpeechAnalyzer`/`SpeechTranscriber` 대신 `SFSpeechRecognizer` 기반으로 빌드되도록 구성했습니다.

## Build
```bash
pod install
```
그 다음 `InferenceExample.xcworkspace`를 열어 빌드합니다.

## CI
- `.github/workflows/ios-ipa.yml` 그대로 사용
- workflow에서 `pod install` 후 `InferenceExample` 스킴 archive + unsigned IPA 생성
