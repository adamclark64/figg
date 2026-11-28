import Foundation

/// Whether one Claude app can read figg's meetings yet.
public enum ClaudeLink: Equatable, Sendable {
    case notInstalled
    case notConnected
    case connected
}

public struct ClaudeStatus: Equatable, Sendable {
    public var desktop: ClaudeLink
    public var code: ClaudeLink
    /// The `claude` command, when Claude Code is installed.
    public var codeCLI: URL?

    public init(desktop: ClaudeLink, code: ClaudeLink, codeCLI: URL? = nil) {
        self.desktop = desktop
        self.code = code
        self.codeCLI = codeCLI
    }

    /// Something is installed and not connected yet: worth suggesting.
    public var canSuggest: Bool { desktop == .notConnected || code == .notConnected }
}

/// Finds Claude Desktop and Claude Code on this Mac and whether figg is
/// connected to each, by reading their own config files. Local file reads
/// only; nothing is sent anywhere, and nothing here writes.
public struct ClaudeDetector: Sendable {
    public static let desktopBundleID = "com.anthropic.claudefordesktop"

    let home: URL
    let desktopInstalled: @Sendable () -> Bool

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                desktopInstalled: @escaping @Sendable () -> Bool) {
        self.home = home
        self.desktopInstalled = desktopInstalled
    }

    public func status() -> ClaudeStatus {
        let cli = codeCLI()
        return ClaudeStatus(
            desktop: !desktopInstalled() ? .notInstalled : desktopConnected() ? .connected : .notConnected,
            code: cli == nil ? .notInstalled : codeConnected() ? .connected : .notConnected,
            codeCLI: cli)
    }

    var desktopSupport: URL { home.appendingPathComponent("Library/Application Support/Claude") }

    /// A `figg` server in Claude Desktop's config, or the figg extension
    /// installed from Settings.
    func desktopConnected() -> Bool {
        if let servers = json(desktopSupport.appendingPathComponent("claude_desktop_config.json"))?["mcpServers"] as? [String: Any],
           servers.contains(where: Self.isFigg) {
            return true
        }
        // Installed from a .mcpb as "Claude Extensions/local.mcpb.figg.figg",
        // with "Claude Extensions Settings/<same>.json" saying whether it is
        // switched on (seen with Claude Desktop 5.11492).
        let extensions = desktopSupport.appendingPathComponent("Claude Extensions")
        let installed = (try? FileManager.default.contentsOfDirectory(atPath: extensions.path)) ?? []
        return installed.contains { id in
            guard id.lowercased().contains(MCPBundle.name) else { return false }
            let settings = json(desktopSupport.appendingPathComponent("Claude Extensions Settings/\(id).json"))
            return settings?["isEnabled"] as? Bool != false
        }
    }

    /// Where the Claude Code installer and package managers put `claude`.
    /// A GUI app has no shell PATH, so these are checked by hand.
    func codeCLI() -> URL? {
        let candidates = [
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// A `figg` server in `~/.claude.json`, for all projects (user scope)
    /// or for any one project.
    func codeConnected() -> Bool {
        guard let config = json(home.appendingPathComponent(".claude.json")) else { return false }
        if let servers = config["mcpServers"] as? [String: Any], servers.contains(where: Self.isFigg) { return true }
        let projects = config["projects"] as? [String: Any] ?? [:]
        return projects.values.contains { project in
            ((project as? [String: Any])?["mcpServers"] as? [String: Any])?.contains(where: Self.isFigg) ?? false
        }
    }

    /// Named figg, or running a figg MCP server under another name.
    static func isFigg(_ entry: (key: String, value: Any)) -> Bool {
        if entry.key.lowercased() == "figg" { return true }
        guard let server = entry.value as? [String: Any] else { return false }
        let parts = [server["command"] as? String ?? ""] + (server["args"] as? [String] ?? [])
        return parts.contains { $0.contains("figg-mcp") }
    }

    private func json(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
