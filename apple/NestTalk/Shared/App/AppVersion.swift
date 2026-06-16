import Foundation

/// App version string for display: marketing version + the build-time git
/// short hash (stamped into the bundle Info.plist as `NTGitHash` by a build
/// phase — see project.yml). Lets a tester confirm at a glance which build is
/// running. Example: `"0.4.0 (a1b2c3d)"` (a trailing `+` means the build had
/// uncommitted changes).
enum AppVersion {
    static var marketing: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// Stamped at build time into `BuildInfo.swift` by the pre-build script.
    static var gitHash: String { BuildInfo.gitHash }

    /// `"0.4.0 (a1b2c3d)"`
    static var string: String { "\(marketing) (\(gitHash))" }
}
