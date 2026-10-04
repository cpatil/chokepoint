import Foundation

/// What build this is. The numbers are stamped into Info.plist by build.sh from
/// git, so nothing here is typed by hand and the app cannot claim to be a version
/// it is not. Read once; a bundle does not change while it runs.
enum AppVersion {
    static let short = string("CFBundleShortVersionString") ?? "0"
    static let build = string("CFBundleVersion") ?? "0"
    static let commit = string("ChokepointCommit") ?? "unknown"
    static let built = string("ChokepointBuilt") ?? ""

    /// "1.0.59" - what a person calls the version.
    static var display: String { short }

    /// "1.0.59 (99) · 3a4da7a · 2026-10-04" - enough to find the exact commit a
    /// report came from. Pure, so the shape is testable without a bundle.
    static var full: String { describe(short: short, build: build, commit: commit, built: built) }

    static func describe(short: String, build: String, commit: String, built: String) -> String {
        var parts = ["\(short) (\(build))"]
        if commit != "unknown", !commit.isEmpty { parts.append(commit) }
        if !built.isEmpty { parts.append(built) }
        return parts.joined(separator: " · ")
    }

    private static func string(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else { return nil }
        return value
    }
}
