// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ytdl",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ytdl", path: "Sources/ytdl")
    ]
)
