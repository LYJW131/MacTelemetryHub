// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacTelemetryHub",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ChargerTelemetryKit", targets: ["ChargerTelemetryKit"]),
    ],
    targets: [
        .target(name: "ChargerTelemetryKit"),
        .testTarget(
            name: "ChargerTelemetryKitTests",
            dependencies: ["ChargerTelemetryKit"]
        ),
    ]
)
