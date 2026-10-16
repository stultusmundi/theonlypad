// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "NativeRouting", platforms: [.macOS(.v14)],
  targets: [
    .target(name: "PadCore"),
    .target(name: "SearchExecution", dependencies: ["PadCore"]),
    .target(name: "NativeRouting", dependencies: ["PadCore", "SearchExecution"]),
    .testTarget(name: "NativeRoutingTests", dependencies: ["NativeRouting", "PadCore"]),
  ], swiftLanguageModes: [.v5])
