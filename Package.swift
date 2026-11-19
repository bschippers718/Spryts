// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Spryts",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "Spryts", path: "Sources/Spryts")
    ]
)
