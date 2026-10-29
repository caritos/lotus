// swift-tools-version: 5.9
import PackageDescription

let strict: [SwiftSetting] = [.enableExperimentalFeature("StrictConcurrency")]

let package = Package(
    name: "Caritos",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CaritosDatabase", targets: ["CaritosDatabase"]),
        .library(name: "CaritosSecurity", targets: ["CaritosSecurity"]),
        .library(name: "CaritosNetworking", targets: ["CaritosNetworking"]),
        .library(name: "CaritosLogging", targets: ["CaritosLogging"]),
        .library(name: "CaritosUI", targets: ["CaritosUI"]),
        .library(name: "CaritosStorage", targets: ["CaritosStorage"]),
    ],
    targets: [
        .target(name: "CaritosDatabase", swiftSettings: strict, linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "CaritosSecurity", swiftSettings: strict),
        .target(name: "CaritosNetworking", swiftSettings: strict),
        .target(name: "CaritosLogging", swiftSettings: strict),
        .target(name: "CaritosUI", swiftSettings: strict),
        .target(name: "CaritosStorage", swiftSettings: strict),
        .testTarget(name: "CaritosDatabaseTests", dependencies: ["CaritosDatabase"], swiftSettings: strict),
        .testTarget(name: "CaritosSecurityTests", dependencies: ["CaritosSecurity"], swiftSettings: strict),
        .testTarget(name: "CaritosNetworkingTests", dependencies: ["CaritosNetworking"], swiftSettings: strict),
        .testTarget(name: "CaritosLoggingTests", dependencies: ["CaritosLogging"], swiftSettings: strict),
        .testTarget(name: "CaritosUITests", dependencies: ["CaritosUI"], swiftSettings: strict),
        .testTarget(name: "CaritosStorageTests", dependencies: ["CaritosStorage"], swiftSettings: strict),
    ]
)
