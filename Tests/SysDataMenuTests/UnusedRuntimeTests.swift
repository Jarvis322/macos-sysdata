import Foundation
import Testing

@testable import SysDataMenu

/// Every Xcode update downloads a runtime and leaves the old one behind, at
/// several gigabytes each. One no SDK is matched to and no simulator is on is
/// one nothing on the Mac can reach.
struct UnusedRuntimeTests {
    /// The shape `simctl runtime match list -j` prints, trimmed.
    private let match: [String: Any] = [
        "iphoneos27.0": ["chosenRuntimeBuild": "24A434", "sdkVersion": "27.0"],
        "watchos27.0": ["chosenRuntimeBuild": "24R362", "sdkVersion": "27.0"],
    ]

    @Test func theBuildsTheSDKsUseAreRead() {
        #expect(RuntimeProbe.chosenBuilds(from: match) == ["24A434", "24R362"])
    }

    @Test func aRuntimeNoSDKChoosesAndNoSimulatorUsesIsUnused() {
        let devices: [String: [Any]] = ["com.apple.CoreSimulator.SimRuntime.iOS-26-4": []]
        #expect(RuntimeProbe.isUnused(
            build: "23E244", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
            chosenBuilds: RuntimeProbe.chosenBuilds(from: match), devices: devices
        ))
    }

    @Test func theRuntimeAnSDKBuildsAgainstIsInUse() {
        #expect(!RuntimeProbe.isUnused(
            build: "24A434", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
            chosenBuilds: RuntimeProbe.chosenBuilds(from: match), devices: [:]
        ))
    }

    /// The case on the Mac this was written on: iOS 27.1 is not what the SDK
    /// picks, but a simulator was made on it by hand.
    @Test func aRuntimeWithASimulatorOnItIsInUse() {
        let devices: [String: [Any]] = ["com.apple.CoreSimulator.SimRuntime.iOS-27-1": [["name": "iPhone 18"]]]
        #expect(!RuntimeProbe.isUnused(
            build: "24A94401", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-1",
            chosenBuilds: RuntimeProbe.chosenBuilds(from: match), devices: devices
        ))
    }

    @Test func withoutTheDeviceListNothingIsClaimed() {
        #expect(!RuntimeProbe.isUnused(
            build: "23E244", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
            chosenBuilds: RuntimeProbe.chosenBuilds(from: match), devices: nil
        ))
    }
}
