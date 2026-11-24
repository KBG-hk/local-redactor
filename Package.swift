// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalRedactor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RedactionCore", targets: ["RedactionCore"]),
        .executable(name: "LocalRedactor", targets: ["LocalRedactor"]),
    ],
    targets: [
        .target(name: "RedactionCore"),
        .executableTarget(name: "LocalRedactor", dependencies: ["RedactionCore"]),
        .testTarget(name: "RedactionCoreTests", dependencies: ["RedactionCore"]),
    ]
)
