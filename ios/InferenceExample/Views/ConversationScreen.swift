import SwiftUI
import UniformTypeIdentifiers

struct ConversationScreen: View {
  @StateObject private var viewModel: ConversationViewModel
  @State private var showingImporter = false

  private var supportedAudioTypes: [UTType] {
    let commonExtensions = ["wav", "mp3", "m4a", "aac", "aiff", "caf"]
    let extensionTypes = commonExtensions.compactMap { UTType(filenameExtension: $0) }
    return [.audio, .mpeg4Audio] + extensionTypes
  }

  init(viewModel: ConversationViewModel = ConversationViewModel()) {
    _viewModel = StateObject(wrappedValue: viewModel)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("iOS Speech 실시간 전사")
          .font(.title2.bold())

        Text(viewModel.statusMessage)
          .font(.footnote)
          .foregroundStyle(.secondary)

        GroupBox("실시간 전사") {
          VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
              RoundedRectButton(
                title: viewModel.isRecording ? "전사 중..." : "실시간 전사 시작",
                role: .primary,
                isDisabled: viewModel.isRecording || viewModel.isBusy
              ) {
                viewModel.startLiveTranscription()
              }

              RoundedRectButton(
                title: "정지",
                role: .secondary,
                isDisabled: !viewModel.isRecording || viewModel.isBusy
              ) {
                viewModel.stopLiveTranscription()
              }
            }

            transcriptCard(text: viewModel.mergedLiveTranscript)
          }
        }

        GroupBox("오디오 파일 업로드 전사") {
          VStack(alignment: .leading, spacing: 12) {
            RoundedRectButton(
              title: "오디오 파일 선택",
              role: .primary,
              isDisabled: viewModel.isBusy
            ) {
              showingImporter = true
            }

            Text(viewModel.selectedFileURL?.lastPathComponent ?? "선택된 파일 없음")
              .font(.footnote)
              .foregroundStyle(.secondary)

            RoundedRectButton(
              title: "선택 파일 전사",
              role: .secondary,
              isDisabled: viewModel.selectedFileURL == nil || viewModel.isBusy
            ) {
              viewModel.transcribeSelectedFile()
            }

            transcriptCard(text: viewModel.fileTranscriptText)
          }
        }

        RoundedRectButton(
          title: "결과 초기화",
          role: .destructive,
          isDisabled: viewModel.isBusy
        ) {
          viewModel.clearAll()
        }
      }
      .padding(16)
    }
    .navigationTitle("Speech Transcriber")
    .fileImporter(
      isPresented: $showingImporter,
      allowedContentTypes: supportedAudioTypes,
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case let .success(urls):
        if let url = urls.first {
          viewModel.setSelectedFile(url: url)
        }
      case let .failure(error):
        viewModel.statusMessage = "파일 선택 실패: \(error.localizedDescription)"
      }
    }
  }

  private func transcriptCard(text: String) -> some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: 10)
        .fill(Color(.secondarySystemBackground))
        .frame(minHeight: 140)

      if text.isEmpty {
        Text("전사 결과가 여기에 표시됩니다.")
          .foregroundStyle(.secondary)
          .padding(12)
      } else {
        Text(text)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
      }
    }
  }
}

#Preview {
  NavigationStack {
    ConversationScreen()
  }
}
