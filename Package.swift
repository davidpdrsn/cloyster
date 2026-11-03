// swift-tools-version: 5.9
import PackageDescription

// The Command Line Tools ship Swift Testing here, but SwiftPM only searches Xcode's location.
let developerFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"

let package = Package(
    name: "cloyster",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CloysterCore"),
        .executableTarget(name: "cloyster", dependencies: ["CloysterCore"]),
        .executableTarget(name: "demo-window"),
        // An executable because `swift test` silently runs nothing without a full Xcode install.
        .executableTarget(
            name: "cloyster-tests",
            dependencies: ["CloysterCore"],
            path: "Tests/CloysterCoreTests",
            swiftSettings: [.unsafeFlags(["-F", developerFrameworks])],
            linkerSettings: [
                .unsafeFlags(["-F", developerFrameworks, "-Xlinker", "-rpath", "-Xlinker", developerFrameworks]),
            ]
        ),
    ]
)
