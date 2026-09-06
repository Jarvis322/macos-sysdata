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
            // The catalogue is the source the .lproj tables are generated
            // from, not a resource. Xcode's build system, which the universal
            // build uses, compiles it into the same files scripts/compile-
            // strings.sh already produced, and the two collide.
            exclude: ["Resources/Localizable.xcstrings"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "SysDataMenuTests",
            dependencies: ["SysDataMenu"],
            path: "Tests/SysDataMenuTests"
        ),
    ]
)
