#if canImport(UIKit)
import UIKit
#endif

/// Tactile feedback. A no-op where UIKit is unavailable (macOS) or without a Taptic Engine.
public enum Haptics {
    /// How hard a physical tap feels: a page turn is `.light`, a drop onto a target `.medium`.
    public enum ImpactStyle: CaseIterable, Sendable {
        case light, medium, heavy
    }

    @MainActor
    public static func success() {
        #if canImport(UIKit) && !os(tvOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    @MainActor
    public static func selection() {
        #if canImport(UIKit) && !os(tvOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    @MainActor
    public static func impact(_ style: ImpactStyle = .light) {
        #if canImport(UIKit) && !os(tvOS)
        let uiStyle: UIImpactFeedbackGenerator.FeedbackStyle
        switch style {
        case .light: uiStyle = .light
        case .medium: uiStyle = .medium
        case .heavy: uiStyle = .heavy
        }
        UIImpactFeedbackGenerator(style: uiStyle).impactOccurred()
        #endif
    }
}
