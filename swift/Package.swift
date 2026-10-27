// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NumidentViewer",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "NumidentCore", targets: ["NumidentCore"]),
        .executable(name: "NumidentViewer", targets: ["NumidentViewer"]),
        .executable(name: "numident-cli", targets: ["numident-cli"]),
        .executable(name: "numident-gen", targets: ["numident-gen"]),
    ],
    targets: [
        .target(name: "NumidentCore"),
        .executableTarget(name: "NumidentViewer", dependencies: ["NumidentCore"]),
        .executableTarget(name: "numident-cli", dependencies: ["NumidentCore"]),
        .executableTarget(name: "numident-gen", dependencies: ["NumidentCore"]),
        .testTarget(name: "NumidentCoreTests", dependencies: ["NumidentCore"]),
    ]
)
