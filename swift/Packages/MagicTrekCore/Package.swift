// swift-tools-version: 5.9
// The rules side of MagicTrek, kept free of UIKit/SwiftUI so it builds and tests on Linux too:
//   CardKit    the card database (cards.json) and the parser that turns rules text into abilities
//   GameEngine the deterministic game: zones, turns, mana, combat, triggers, the computer player
import PackageDescription

let package = Package(
    name: "MagicTrekCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CardKit", targets: ["CardKit"]),
        .library(name: "GameEngine", targets: ["GameEngine"]),
    ],
    targets: [
        .target(name: "CardKit", resources: [.copy("Resources/cards.json")]),
        .target(name: "GameEngine", dependencies: ["CardKit"]),
        .executableTarget(name: "CardTool", dependencies: ["CardKit"]),
        .executableTarget(name: "SimTool", dependencies: ["CardKit", "GameEngine"]),
        .testTarget(name: "CardKitTests", dependencies: ["CardKit"]),
        .testTarget(name: "GameEngineTests", dependencies: ["GameEngine", "CardKit"]),
    ]
)
