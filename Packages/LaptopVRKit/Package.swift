// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LaptopVRKit",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "LaptopVRKit", targets: ["VRProtocol", "VRTransport", "VRVideo"]),
        .library(name: "CGVirtualDisplayPrivate", targets: ["CGVirtualDisplayPrivate"]),
    ],
    targets: [
        .target(name: "VRProtocol"),
        .target(name: "VRTransport", dependencies: ["VRProtocol"]),
        .target(name: "VRVideo", dependencies: ["VRProtocol"]),
        .target(name: "CGVirtualDisplayPrivate", publicHeadersPath: "include"),
    ]
)
