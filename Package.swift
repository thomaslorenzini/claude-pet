// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClaudePet",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ClaudePet",
            path: "Sources/ClaudePet"
        ),
    ]
)
