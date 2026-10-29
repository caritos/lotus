import SwiftUI

/// An inline error message with an optional Retry button. Uses system colors only.
public struct ErrorBanner: View {
    private let message: String
    private let retry: (() -> Void)?

    public init(message: String, retry: (() -> Void)? = nil) {
        self.message = message
        self.retry = retry
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                // The message is the one element VoiceOver reads ("Error: ..."); Retry stays separate.
                .accessibilityLabel("Error: \(message)")
            if let retry {
                Button(action: retry) {
                    Text("Retry")
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}
