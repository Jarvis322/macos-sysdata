// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SysDataMenu",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SysDataMenu",
            path: "Sources/SysDataMenu",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "SysDataMenuTests",
            dependencies: ["SysDataMenu"],
            path: "Tests/SysDataMenuTests"
        ),
    ]
)
