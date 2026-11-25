@testable import FiggClaude
import Foundation
import Testing

/// A fake home folder with whichever Claude files a test writes.
private struct Home {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-home-\(UUID().uuidString)")

    func write(_ path: String, _ json: Any) throws {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: file)
    }

    func makeCLI() throws {
        let cli = url.appendingPathComponent(".local/bin/claude")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
    }

    func status(desktop: Bool) -> ClaudeStatus {
        ClaudeDetector(home: url, desktopInstalled: { desktop }).status()
    }
}

private let desktopConfig = "Library/Application Support/Claude/claude_desktop_config.json"

@Suite struct ClaudeDetectorTests {
    @Test func nothingInstalled() {
        let s = Home().status(desktop: false)
        // /opt/homebrew or /usr/local may hold a real `claude` on this Mac;
        // only Desktop is fully faked here.
        #expect(s.desktop == .notInstalled)
    }

    @Test func desktopInstalledButNotConnected() throws {
        let home = Home()
        #expect(home.status(desktop: true).desktop == .notConnected)
        try home.write(desktopConfig, ["mcpServers": ["other": ["command": "/bin/other"]], "preferences": [:]])
        #expect(home.status(desktop: true).desktop == .notConnected)
        #expect(home.status(desktop: true).canSuggest)
    }

    @Test func desktopConnectedByConfigByCommandOrByExtension() throws {
        let byName = Home()
        try byName.write(desktopConfig, ["mcpServers": ["figg": ["command": "/opt/homebrew/bin/node"]]])
        #expect(byName.status(desktop: true).desktop == .connected)

        let byCommand = Home()
        try byCommand.write(desktopConfig, ["mcpServers": ["meetings": ["command": "/Applications/Figg.app/Contents/MacOS/figg-mcp"]]])
        #expect(byCommand.status(desktop: true).desktop == .connected)

        let byExtension = Home()
        try FileManager.default.createDirectory(
            at: byExtension.url.appendingPathComponent("Library/Application Support/Claude/Claude Extensions/local.mcpb.figg.figg"),
            withIntermediateDirectories: true)
        #expect(byExtension.status(desktop: true).desktop == .connected)
        let settings = "Library/Application Support/Claude/Claude Extensions Settings/local.mcpb.figg.figg.json"
        try byExtension.write(settings, ["isEnabled": true])
        #expect(byExtension.status(desktop: true).desktop == .connected)
        try byExtension.write(settings, ["isEnabled": false])
        #expect(byExtension.status(desktop: true).desktop == .notConnected, "switched off in Claude")
    }

    @Test func claudeCodeByCLIAndConfig() throws {
        let home = Home()
        try home.makeCLI()
        var s = home.status(desktop: false)
        #expect(s.code == .notConnected)
        #expect(s.codeCLI?.lastPathComponent == "claude")
        #expect(s.canSuggest)

        try home.write(".claude.json", ["projects": ["/repo": ["mcpServers": ["figg": ["command": "x"]]]]])
        #expect(home.status(desktop: false).code == .connected, "a per-project entry counts")

        try home.write(".claude.json", ["mcpServers": ["figg": ["command": "x"]]])
        s = home.status(desktop: false)
        #expect(s.code == .connected)
        #expect(!s.canSuggest)
    }

    @Test func malformedConfigIsNotConnected() throws {
        let home = Home()
        let file = home.url.appendingPathComponent(desktopConfig)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{ not json".write(to: file, atomically: true, encoding: .utf8)
        #expect(home.status(desktop: true).desktop == .notConnected)
    }
}

@Suite struct MCPBundleTests {
    let server = URL(fileURLWithPath: "/Applications/Figg.app/Contents/MacOS/figg-mcp")

    @Test func manifestRunsTheAppsServer() throws {
        let m = try #require(try JSONSerialization.jsonObject(with: MCPBundle.manifest(server: server, version: "0.11.0")) as? [String: Any])
        for key in ["manifest_version", "name", "version", "description", "author", "server"] { #expect(m[key] != nil, "\(key)") }
        #expect(m["name"] as? String == "figg")
        #expect(m["version"] as? String == "0.11.0")
        let s = try #require(m["server"] as? [String: Any])
        #expect(s["type"] as? String == "binary")
        #expect((s["mcp_config"] as? [String: Any])?["command"] as? String == server.path)
        #expect((m["tools"] as? [[String: Any]])?.count == 5)
    }

    @Test func writesAZipWithTheManifestAtTheRoot() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcpb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = try MCPBundle.write(server: server, version: "0.11.0", icon: nil, into: dir)
        #expect(file.lastPathComponent == "figg.mcpb")
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-Z1", file.path]
        let out = Pipe()
        unzip.standardOutput = out
        try unzip.run()
        unzip.waitUntilExit()
        let names = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(names.split(separator: "\n") == ["manifest.json"])
    }
}

@Suite struct ClaudeCodeSetupTests {
    @Test func commandQuotesPathsWithSpaces() {
        let server = URL(fileURLWithPath: "/Users/me/My Apps/Figg.app/Contents/MacOS/figg-mcp")
        #expect(ClaudeCodeSetup.arguments(server: server) == ["mcp", "add", "--scope", "user", "figg", "--", server.path])
        #expect(ClaudeCodeSetup.command(server: server)
            == "claude mcp add --scope user figg -- '/Users/me/My Apps/Figg.app/Contents/MacOS/figg-mcp'")
    }
}
