import SwiftUI

/// Splits a 0xRRGGBB value into sRGB components in 0...1. Pure, so it is unit tested.
public enum HexColor {
    public static func components(_ hex: UInt32) -> (red: Double, green: Double, blue: Double) {
        (
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

public extension Color {
    /// An opaque sRGB color from a 0xRRGGBB value.
    init(hex: UInt32) {
        let c = HexColor.components(hex)
        self.init(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: 1)
    }
}
