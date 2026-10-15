// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "NativeRouting", platforms: [.macOS(.v14)],
  products: [.executable(name: "PadSearchWorker", targets: ["PadSearchWorker"])],
  targets: [
    .target(name: "PadCore"), .target(name: "SearchExecution", dependencies: ["PadCore"]),
    .target(name: "PadSearchWorkerRuntime", dependencies: ["PadCore", "SearchExecution"]),
    .executableTarget(
      name: "PadSearchWorker", dependencies: ["PadSearchWorkerRuntime", "SearchExecution"]),
    .target(name: "NativeRouting", dependencies: ["PadCore", "SearchExecution"]),
    .testTarget(
      name: "NativeRoutingTests", dependencies: ["NativeRouting", "PadCore", "SearchExecution"]),
  ], swiftLanguageModes: [.v5])
