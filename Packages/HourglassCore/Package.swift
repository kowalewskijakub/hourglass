// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HourglassCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "HourglassCore", targets: ["HourglassCore"]),
        .executable(name: "hourglass-selfcheck", targets: ["HourglassCoreSelfCheck"]),
    ],
    targets: [
        .target(
            name: "HourglassCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // A dependency-free smoke test runnable with just the Command Line Tools
        // (`swift run hourglass-selfcheck`). The exhaustive suite lives in the
        // XCTest/Swift Testing target, which needs full Xcode to run.
        .executableTarget(
            name: "HourglassCoreSelfCheck",
            dependencies: ["HourglassCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "HourglassCoreTests",
            dependencies: ["HourglassCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
