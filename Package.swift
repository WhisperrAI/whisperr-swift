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
        ),
        // Rich push: link this product to a Notification Service Extension
        // target only. It does not depend on Whisperr.
        .library(
            name: "WhisperrNotificationServiceExtension",
            targets: ["WhisperrNotificationServiceExtension"]
        )
    ],
    targets: [
        .target(
            name: "Whisperr",
            // Apple privacy manifest: required-reason APIs and collected data.
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .target(
            name: "WhisperrNotificationServiceExtension",
            // Collects no data and uses no required-reason API.
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "WhisperrTests",
            dependencies: ["Whisperr"]
        ),
        .testTarget(
            name: "WhisperrNotificationServiceExtensionTests",
            dependencies: ["WhisperrNotificationServiceExtension"]
        )
    ]
)
