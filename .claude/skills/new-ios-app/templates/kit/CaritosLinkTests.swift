import Testing
import CaritosLogging

// Proves the app is linked to the shared Caritos package copied into ios/Caritos.
@Test func caritosPackageIsLinked() {
    #expect(LogLevel.error > LogLevel.debug)
}
