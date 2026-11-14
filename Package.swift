// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Spryts",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Spryts", path: "Sources/Spryts")
    ]
)
