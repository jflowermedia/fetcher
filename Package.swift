// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Fetcher",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Fetcher", path: "Sources/Fetcher")
    ]
)
