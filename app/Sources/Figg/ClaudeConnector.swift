import AppKit
import FiggClaude
import Foundation

/// figg's link to Claude Desktop and Claude Code: whether each is installed
/// and connected, and connecting them. Shared by Settings and the one-time
/// card after a meeting. Checks are local file reads; refreshed whenever
/// figg comes to the front, so a change made in Claude shows up.
@MainActor
final class ClaudeConnector: ObservableObject {
    @Published private(set) var status = ClaudeStatus(desktop: .notInstalled, code: .notInstalled)
    @Published private(set) var message: String?
    /// Set when `claude mcp add` could not run, for the user to paste.
    @Published private(set) var codeCommand: String?

    private let detector = ClaudeDetector(desktopInstalled: { ClaudeConnector.desktopApp != nil })

    init() {
        refresh()
    }

    /// figg-mcp sits beside the app binary in Figg.app/Contents/MacOS.
    /// Nil in a `swift run` build, which has no app bundle.
    var server: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/figg-mcp")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    nonisolated static var desktopApp: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: ClaudeDetector.desktopBundleID)
    }

    func refresh() {
        let new = detector.status()
        if new != status { status = new }
        if status.desktop == .connected, status.code == .connected { message = nil }
    }

    /// Makes the extension file and hands it to Claude Desktop, which asks
    /// the user to install it. Claude's own dialog is the confirmation.
    func connectDesktop() {
        guard let server, let app = Self.desktopApp else { return }
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("figg-claude", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
            let icon = Bundle.main.url(forResource: "ClaudeIcon", withExtension: "png")
            let bundle = try MCPBundle.write(server: server, version: version, icon: icon, into: folder)
            NSWorkspace.shared.open([bundle], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            message = "Claude Desktop is asking to install figg. Click Install there, then start a new chat."
        } catch {
            message = "Could not make the Claude Desktop extension: \(error.localizedDescription)"
        }
    }

    /// Runs `claude mcp add`; if that fails, shows the command to run by hand.
    func connectCode() {
        guard let server, let cli = status.codeCLI else { return }
        do {
            try ClaudeCodeSetup.add(cli: cli, server: server)
            codeCommand = nil
            message = "Added. New Claude Code sessions can read your meetings."
        } catch {
            codeCommand = ClaudeCodeSetup.command(server: server)
            message = "Claude Code said: \(error.localizedDescription) You can run the command below in a terminal instead."
        }
        refresh()
    }

    func copyCodeCommand() {
        guard let command = codeCommand ?? server.map(ClaudeCodeSetup.command) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
}
