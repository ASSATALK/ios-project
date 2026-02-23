# ios-project

`ios/InferenceExample`는 iOS Speech framework 기반 실시간/파일 음성 전사 앱입니다.

## 핵심 기능
- `SpeechAnalyzer` + `SpeechTranscriber` 기반 실시간 마이크 전사
- 파일 선택(`fileImporter`) 후 오디오 파일 전사
- 결과 텍스트 즉시 확인/초기화

## 빌드 경로
GitHub Actions 빌드 경로는 기존과 동일하게 유지됩니다.
- workflow: `.github/workflows/ios-ipa.yml`
- workspace: `ios/InferenceExample.xcworkspace`
- scheme: `InferenceExample`
- 산출물: unsigned `.ipa` artifact

## 로컬 실행
1. `cd ios`
2. `pod install`
3. `InferenceExample.xcworkspace` 열기
4. 실제 iPhone에서 마이크 권한/음성 인식 권한 허용 후 테스트
