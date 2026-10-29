// swift-tools-version: 5.9
import PackageDescription

// All testable logic lives here; the app target stays thin SwiftUI.
// macOS is listed so `swift test` runs on the Mac with no simulator.
// Caritos is the shared package copied into ios/Caritos (a snapshot; see the skill's SKILL.md).
let package = Package(
    name: "__APP__Kit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "__APP__Kit", targets: ["__APP__Kit"])],
    dependencies: [.package(path: "Caritos")],
    targets: [
        .target(name: "__APP__Kit", dependencies: [.product(name: "CaritosLogging", package: "Caritos")]),
        .testTarget(name: "__APP__KitTests", dependencies: ["__APP__Kit", .product(name: "CaritosLogging", package: "Caritos")]),
    ]
)
