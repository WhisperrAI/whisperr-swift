// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "whisperr-swift",
    platforms: [
        .iOS(.v13),
        .macOS(.v12),
        .tvOS(.v13),
        .watchOS(.v6)
    ],
    products: [
        .library(
            name: "Whisperr",
            targets: ["Whisperr"]
        )
    ],
    targets: [
        .target(
            name: "Whisperr"
        ),
        .testTarget(
            name: "WhisperrTests",
            dependencies: ["Whisperr"]
        )
    ]
)
