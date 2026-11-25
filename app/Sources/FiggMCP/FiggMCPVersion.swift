import Foundation

/// The figg version this server shipped with. figg-mcp sits in
/// Figg.app/Contents/MacOS beside the app, so it reads the app's
/// Info.plist; a build outside the app reports "dev".
public enum FiggMCPVersion {
    public static var current: String {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let plist = exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        guard let info = NSDictionary(contentsOf: plist),
              let version = info["CFBundleShortVersionString"] as? String else { return "dev" }
        return version
    }
}
