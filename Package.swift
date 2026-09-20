// swift-tools-version: 6.2
import PackageDescription

let swift6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "SnappySnap",
    // Required as soon as a target carries localized resources. Every target's `.lproj` directories
    // are `en` and `fr`; a system asking for anything else is served `en`.
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "SnapCore", resources: [.process("Resources")], swiftSettings: swift6),
        .target(name: "SystemAdapters", dependencies: ["SnapCore"],
                resources: [.process("Resources")], swiftSettings: swift6),
        .executableTarget(
            name: "SnappySnap",
            dependencies: ["SnapCore", "SystemAdapters"],
            resources: [.process("Resources")],
            swiftSettings: swift6
        ),
        .executableTarget(name: "axprobe", dependencies: ["SystemAdapters"],
                          path: "Tools/axprobe", swiftSettings: swift6),
        .testTarget(name: "SnapCoreTests", dependencies: ["SnapCore"], swiftSettings: swift6),
        .testTarget(name: "SystemAdaptersTests", dependencies: ["SystemAdapters", "SnapCore"], swiftSettings: swift6),
    ]
)
