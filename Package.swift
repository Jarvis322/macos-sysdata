// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SysDataMenu",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "WidgetSnapshot",
            path: "Sources/WidgetSnapshot"
        ),
        // The desktop widget. Built as an executable and packed into the app
        // as PlugIns/SysDataWidget.appex by scripts/build-app.sh, since SwiftPM
        // has no app-extension product.
        .executableTarget(
            name: "SysDataWidget",
            dependencies: ["WidgetSnapshot"],
            path: "Sources/SysDataWidget"
        ),
        .executableTarget(
            name: "SysDataMenu",
            dependencies: ["WidgetSnapshot"],
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
