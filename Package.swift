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
        /**
         * 上报信封、上传指纹、SigV4 直传这些纯逻辑。
         *
         * 和 ChargerTelemetryKit 一样，Xcode 那侧是把源文件直接编进 App target
         * 的，不走 package product —— 所以这里的类型一律 internal，进了 App 就
         * 和 App 同一个模块。只有 SPM 这侧需要 `import ChargerTelemetryKit`，
         * 用 TELEMETRY_CORE_SPM 隔开：App target 里没有那个模块可导。
         */
        .target(
            name: "TelemetryCore",
            dependencies: ["ChargerTelemetryKit"],
            swiftSettings: [.define("TELEMETRY_CORE_SPM")]
        ),
        .target(name: "CodingUsageKit"),
        .testTarget(name: "CodingUsageKitTests", dependencies: ["CodingUsageKit"]),
        .testTarget(
            name: "ChargerTelemetryKitTests",
            dependencies: ["ChargerTelemetryKit"]
        ),
        .testTarget(
            name: "TelemetryCoreTests",
            dependencies: ["TelemetryCore", "ChargerTelemetryKit"]
        ),
    ]
)
