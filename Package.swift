// swift-tools-version: 6.0
import PackageDescription

// Record the real SDK in the app. Some SwiftPM toolchains record the deployment target instead,
// and AppKit then draws windows with older styling. scripts/toolchain.sh sets the version.
let linkApp: [LinkerSetting] =
  Context.environment["BRISTLE_SDK_VERSION"].map {
    [.unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "13.0", "-Xlinker", $0])]
  } ?? []
let checking = Context.environment["BRISTLE_CHECKS"] == "1"

let package = Package(
  name: "Bristle", platforms: [.macOS(.v13)],
  products: [
    .executable(name: "Bristle", targets: ["Bristle"]),
    // The drawing canvas, for other apps.
    .library(name: "BristleCanvas", targets: ["BristleCanvas"]),
  ],
  targets: [
    .target(name: "BristleCore"),
    .target(
      name: "BristleCanvas", dependencies: ["BristleCore"],
      // The app's checks look inside the canvas with @testable import.
      swiftSettings: checking ? [.define("BRISTLE_CHECKS"), .unsafeFlags(["-enable-testing"])] : []),
    .executableTarget(
      name: "Bristle", dependencies: ["BristleCore", "BristleCanvas"], exclude: checking ? [] : ["AppChecks.swift"],
      swiftSettings: checking ? [.define("BRISTLE_CHECKS")] : [], linkerSettings: linkApp),
    .testTarget(name: "BristleCoreTests", dependencies: ["BristleCore"]),
    .testTarget(name: "BristleCanvasTests", dependencies: ["BristleCore", "BristleCanvas"], exclude: ["Fixtures"]),
  ])
