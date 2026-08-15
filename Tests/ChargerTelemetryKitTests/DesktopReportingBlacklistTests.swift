import Testing

@testable import ChargerTelemetryKit

@Test func desktopReportingBlacklistNormalizesAndDeduplicatesBundleIDs() {
    let blacklist = DesktopReportingBlacklist(
        rawValue: "  com.apple.Terminal\nCOM.APPLE.TERMINAL, com.example.Secret；com.example.Other  "
    )

    #expect(blacklist.bundleIdentifiers == [
        "com.apple.Terminal",
        "com.example.Secret",
        "com.example.Other",
    ])
    #expect(blacklist.normalizedRawValue == "com.apple.Terminal\ncom.example.Secret\ncom.example.Other")
}

@Test func desktopReportingBlacklistMatchesExactBundleIDIgnoringCase() {
    let blacklist = DesktopReportingBlacklist(rawValue: "com.example.Secret")

    #expect(blacklist.contains(bundleIdentifier: "COM.EXAMPLE.SECRET"))
    #expect(!blacklist.contains(bundleIdentifier: "com.example.Secret.Helper"))
    #expect(!blacklist.contains(bundleIdentifier: nil))
}

@Test func bundleIdentifierListDefaultsToMatchingNothing() {
    let whitelist = BundleIdentifierList(rawValue: "")

    #expect(whitelist.bundleIdentifiers.isEmpty)
    #expect(!whitelist.contains(bundleIdentifier: "com.example.App"))
}
