// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SysDataMenu",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SysDataMenu",
            path: "Sources/SysDataMenu"
        ),
        .testTarget(
            name: "SysDataMenuTests",
            dependencies: ["SysDataMenu"],
            path: "Tests/SysDataMenuTests"
        ),
    ]
)
