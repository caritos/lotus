// swift-tools-version: 5.9
import PackageDescription

// All testable logic lives here; the app target stays thin SwiftUI.
// macOS is listed so `swift test` runs on the Mac with no simulator.
let package = Package(
    name: "__APP__Kit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "__APP__Kit", targets: ["__APP__Kit"])],
    targets: [
        .target(name: "__APP__Kit"),
        .testTarget(name: "__APP__KitTests", dependencies: ["__APP__Kit"]),
    ]
)
