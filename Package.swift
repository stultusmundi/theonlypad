// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TheOnlyPad",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "PadCore", targets: ["PadCore"]),
    .executable(name: "TheOnlyPad", targets: ["TheOnlyPad"]),
    .executable(name: "PadSearchWorker", targets: ["PadSearchWorker"]),
  ],
  targets: [
    .target(name: "PadCore"),
    .target(name: "SearchExecution", dependencies: ["PadCore"]),
    .target(name: "PadSearchWorkerRuntime", dependencies: ["PadCore", "SearchExecution"]),
    .executableTarget(
      name: "PadSearchWorker", dependencies: ["PadSearchWorkerRuntime", "SearchExecution"]),
    .testTarget(
      name: "PadSearchWorkerRuntimeTests",
      dependencies: ["PadSearchWorkerRuntime", "PadCore", "SearchExecution"]),
    .executableTarget(name: "TheOnlyPad", dependencies: ["PadCore", "SearchExecution"]),
    .testTarget(name: "PadCoreTests", dependencies: ["PadCore"]),
    .testTarget(name: "SearchExecutionTests", dependencies: ["SearchExecution", "PadCore"]),
  ],
  swiftLanguageModes: [.v5]
)
