// swift-tools-version: 6.0
// KeymendCore: the word engine and keyboard bridge logic, with no UI.
// Apple frameworks only; no third-party dependencies.
import PackageDescription

let package = Package(
    name: "KeymendCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KeymendCore", targets: ["KeymendCore"]),
    ],
    targets: [
        .target(name: "KeymendCore"),
        .testTarget(name: "KeymendCoreTests", dependencies: ["KeymendCore"]),
    ]
)
