import SwiftUI

/// A settings line: title on the left, optional secondary value on the right.
/// Wrap it in a Button or Link when the row should do something.
public struct SettingsRow: View {
    private let title: String
    private let value: String?

    public init(title: String, value: String? = nil) {
        self.title = title
        self.value = value
    }

    public var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
