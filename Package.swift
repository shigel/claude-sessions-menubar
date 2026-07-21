// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeSessions",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "ClaudeSessions",
            path: "Sources/ClaudeSessions"
        )
    ]
)
