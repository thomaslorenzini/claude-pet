// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClaudePet",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Self-updates (download, EdDSA check, replace, relaunch). Pinned: a new version is a deliberate change.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "ClaudePet",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/ClaudePet",
            // POST /control (tests only) exists in debug builds. A release build gets it only on request,
            // in its own build folder (scripts/build-test-release.sh), never in the published app.
            swiftSettings: [.define("TEST_CONTROL", .when(configuration: .debug))],
            // Sparkle.framework: next to the binary in .build, in Contents/Frameworks in the .app
            // (copied by scripts/bundle.sh).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path",
                                           "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ]
)
