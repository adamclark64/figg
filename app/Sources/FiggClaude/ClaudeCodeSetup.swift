import Foundation

/// Adds figg to Claude Code for all projects, the same as running
/// `claude mcp add --scope user figg -- <figg-mcp>` in a terminal.
public enum ClaudeCodeSetup {
    public static func arguments(server: URL) -> [String] {
        ["mcp", "add", "--scope", "user", "figg", "--", server.path]
    }

    /// The command to paste into a terminal when figg cannot run it.
    public static func command(server: URL) -> String {
        "claude " + arguments(server: server).map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
    }

    /// Runs `claude mcp add`. Throws with Claude Code's own message on failure.
    public static func add(cli: URL, server: URL) throws {
        let p = Process()
        p.executableURL = cli
        p.arguments = arguments(server: server)
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CocoaError(.executableLoad, userInfo: [
                NSLocalizedDescriptionKey: message.isEmpty ? "claude mcp add failed." : message,
            ])
        }
    }
}
