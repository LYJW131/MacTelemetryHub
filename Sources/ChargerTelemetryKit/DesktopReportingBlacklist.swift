import Foundation

/// Bundle ID 配置列表。匹配时忽略大小写，展示时保留首次输入。
struct BundleIdentifierList: Equatable, Sendable {
    let bundleIdentifiers: [String]

    init(rawValue: String) {
        let separators = CharacterSet.newlines.union(CharacterSet(charactersIn: ",;，；"))
        var seen: Set<String> = []
        bundleIdentifiers = rawValue
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { value in
                guard !value.isEmpty else { return false }
                return seen.insert(value.lowercased()).inserted
            }
    }

    var normalizedRawValue: String {
        bundleIdentifiers.joined(separator: "\n")
    }

    func contains(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        let normalized = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return bundleIdentifiers.contains { $0.lowercased() == normalized }
    }
}

typealias DesktopReportingBlacklist = BundleIdentifierList
