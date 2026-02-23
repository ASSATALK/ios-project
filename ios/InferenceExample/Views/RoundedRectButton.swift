import SwiftUI

struct RoundedRectButton: View {
  enum Role {
    case primary
    case secondary
    case destructive
  }

  let title: String
  let role: Role
  let isDisabled: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.subheadline.bold())
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.white)
    .background(backgroundColor)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .opacity(isDisabled ? 0.5 : 1)
    .disabled(isDisabled)
  }

  private var backgroundColor: Color {
    switch role {
    case .primary:
      return Metadata.brandColor
    case .secondary:
      return .gray
    case .destructive:
      return .red
    }
  }
}
