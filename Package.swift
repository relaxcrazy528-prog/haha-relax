// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeepOnline",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KeepOnlineCore", targets: ["KeepOnlineCore"]),
        .library(name: "KeepOnlinePlatform", targets: ["KeepOnlinePlatform"]),
        .executable(name: "KeepOnline", targets: ["KeepOnlineApp"])
    ],
    targets: [
        .target(name: "KeepOnlineCore"),
        .target(name: "KeepOnlinePlatform", dependencies: ["KeepOnlineCore"], linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("Network")]),
        .executableTarget(name: "KeepOnlineApp", dependencies: ["KeepOnlineCore", "KeepOnlinePlatform"], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI"), .linkedFramework("ServiceManagement")]),
        .executableTarget(name: "LeaseProbe", dependencies: ["KeepOnlineCore", "KeepOnlinePlatform"], path: "Tools/LeaseProbe"),
        .testTarget(name: "KeepOnlineCoreTests", dependencies: ["KeepOnlineCore"]),
        .testTarget(name: "KeepOnlinePlatformTests", dependencies: ["KeepOnlinePlatform", "KeepOnlineCore"])
    ]
)
