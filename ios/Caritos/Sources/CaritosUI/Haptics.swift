#if canImport(UIKit)
import UIKit
#endif

/// Tactile feedback. A no-op where UIKit is unavailable (macOS) or without a Taptic Engine.
public enum Haptics {
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
}
