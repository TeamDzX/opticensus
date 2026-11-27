// swift-tools-version:5.9
import PackageDescription

// The product name lives in Sources/OptiCensusCore/Product.swift; the target
// names below are the only other place it appears.
let package = Package(
    name: "OptiCensus",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "opticensus", targets: ["opticensus"]),
        .library(name: "OptiCensusCore", targets: ["OptiCensusCore"]),
    ],
    targets: [
        .target(name: "OptiCensusCore"),
        .executableTarget(name: "opticensus", dependencies: ["OptiCensusCore"]),
        .testTarget(name: "OptiCensusCoreTests", dependencies: ["OptiCensusCore"]),
    ]
)
