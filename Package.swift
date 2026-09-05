// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacTelemetryHub",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "coding-usage", targets: ["CodingUsageDiagnostic"]),
        .library(name: "ChargerTelemetryKit", targets: ["ChargerTelemetryKit"]),
        .library(name: "CodingUsageKit", targets: ["CodingUsageKit"]),
    ],
    targets: [
        .executableTarget(name: "CodingUsageDiagnostic", dependencies: ["CodingUsageKit"]),
        .target(name: "ChargerTelemetryKit"),
        .target(name: "CodingUsageKit"),
        .testTarget(name: "CodingUsageKitTests", dependencies: ["CodingUsageKit"]),
        .testTarget(
            name: "ChargerTelemetryKitTests",
            dependencies: ["ChargerTelemetryKit"]
        ),
    ]
)
