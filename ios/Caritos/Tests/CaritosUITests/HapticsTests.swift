import Testing
@testable import CaritosUI

@MainActor
struct HapticsTests {
    @Test("impact has light, medium and heavy styles")
    func impactStyles() {
        #expect(Haptics.ImpactStyle.allCases == [.light, .medium, .heavy])
    }

    @Test("impact is a safe no-op where there is no Taptic Engine, for every style")
    func impactDoesNotCrashOnTheMac() {
        for style in Haptics.ImpactStyle.allCases { Haptics.impact(style) }
        Haptics.impact()   // defaults to light
    }
}
