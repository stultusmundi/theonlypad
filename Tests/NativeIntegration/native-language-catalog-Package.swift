// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: "NativeLanguageCatalog",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "PadCore"),
    .target(name: "NativeLanguageCatalogComponent", dependencies: ["PadCore"]),
    .testTarget(
      name: "NativeLanguageCatalogOwnerTests",
      dependencies: ["NativeLanguageCatalogComponent", "PadCore"]),
  ],
  swiftLanguageModes: [.v5]
)
