// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KataLog",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "KataLog", targets: ["KataLog"]),
        .executable(name: "katalog-cli", targets: ["KataLogCLI"])
    ],
    targets: [
        .target(name: "KataLogCore"),
        .executableTarget(name: "KataLog", dependencies: ["KataLogCore"], resources: [.copy("Resources")]),
        .executableTarget(name: "KataLogCLI", dependencies: ["KataLogCore"]),
        .testTarget(name: "KataLogCoreTests", dependencies: ["KataLogCore"]),
        .testTarget(name: "KataLogAppTests", dependencies: ["KataLog"])
    ]
)
