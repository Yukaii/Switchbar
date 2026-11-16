import AppKit

/// Build metadata. Release builds get these values from the Info.plist that
/// `scripts/build-app.sh` generates (copied into the .app and also embedded in the
/// executable's `__TEXT,__info_plist` section, so the bare Homebrew binary has
/// them too). Plain `swift build` / `swift run` builds fall back to "dev".
enum AppInfo {
    static let fallbackBundleIdentifier = "com.yukaii.Switchbar"

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? fallbackBundleIdentifier
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var build: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    static var commit: String? {
        Bundle.main.object(forInfoDictionaryKey: "SwitchbarGitCommit") as? String
    }

    static var isDevelopmentBuild: Bool {
        version == "dev"
    }

    /// e.g. "Version 1.1.0 (42)" or "Development build".
    static var versionDescription: String {
        guard !isDevelopmentBuild else { return "Development build" }
        if let build, build != version {
            return "Version \(version) (\(build))"
        }
        return "Version \(version)"
    }

    static let repositoryURL = URL(string: "https://github.com/Yukaii/Switchbar")!
    static let releasesURL = URL(string: "https://github.com/Yukaii/Switchbar/releases")!
    static let issuesURL = URL(string: "https://github.com/Yukaii/Switchbar/issues")!
    static let inspirationURL = URL(string: "https://sindresorhus.com/default-browser")!
}
