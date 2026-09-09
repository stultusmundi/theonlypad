// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TheOnlyPad",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "PadCore", targets: ["PadCore"]),
    .executable(name: "TheOnlyPad", targets: ["TheOnlyPad"]),
  ],
  targets: [
    .target(name: "PadCore"),
    .executableTarget(name: "TheOnlyPad", dependencies: ["PadCore"]),
    .testTarget(name: "PadCoreTests", dependencies: ["PadCore"]),
  ],
  swiftLanguageModes: [.v5]
)
