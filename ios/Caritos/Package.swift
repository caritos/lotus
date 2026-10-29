// swift-tools-version: 5.9
import PackageDescription

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
        .target(name: "CaritosDatabase", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "CaritosSecurity"),
        .target(name: "CaritosNetworking"),
        .target(name: "CaritosLogging"),
        .target(name: "CaritosUI"),
        .target(name: "CaritosStorage"),
        .testTarget(name: "CaritosDatabaseTests", dependencies: ["CaritosDatabase"]),
        .testTarget(name: "CaritosSecurityTests", dependencies: ["CaritosSecurity"]),
        .testTarget(name: "CaritosNetworkingTests", dependencies: ["CaritosNetworking"]),
        .testTarget(name: "CaritosLoggingTests", dependencies: ["CaritosLogging"]),
        .testTarget(name: "CaritosUITests", dependencies: ["CaritosUI"]),
        .testTarget(name: "CaritosStorageTests", dependencies: ["CaritosStorage"]),
    ]
)
