import Foundation

/// A Claude Desktop extension (`.mcpb`: a zip with `manifest.json` at its
/// root) that runs the figg-mcp inside Figg.app. Opening the file makes
/// Claude Desktop show its own Install dialog, so figg never edits Claude's
/// config (which Claude rewrites from memory while it runs).
///
/// The command is the absolute path of the figg-mcp beside the running
/// app, so the extension updates whenever figg does. Moving Figg.app breaks
/// it; Settings then shows "not connected" and connecting again fixes it.
/// Spec: github.com/modelcontextprotocol/mcpb, MANIFEST.md.
public enum MCPBundle {
    public static let name = "figg"

    public static func manifest(server: URL, version: String) throws -> Data {
        let manifest: [String: Any] = [
            "manifest_version": "0.3",
            "name": name,
            "display_name": "figg meetings",
            "version": version,
            "description": "Lets Claude read your figg meetings on this Mac: titles, notes, enhanced notes and transcripts. Read-only.",
            "long_description": "Claude can list, search and read the meetings figg recorded on this Mac. It cannot change or delete them, and never gets audio. Whatever Claude reads is sent to Anthropic as part of the conversation, like text you paste in.",
            "author": ["name": "figg", "url": "https://github.com/adamclark64/figg"],
            "homepage": "https://github.com/adamclark64/figg",
            "server": [
                "type": "binary",
                "entry_point": server.path,
                "mcp_config": ["command": server.path, "args": [String]()],
            ],
            "tools": [
                ["name": "list_meetings", "description": "List meetings, newest first, by date."],
                ["name": "search_meetings", "description": "Search titles, notes and transcripts."],
                ["name": "get_meeting", "description": "Read one meeting's notes."],
                ["name": "get_meetings", "description": "Read several meetings' notes at once."],
                ["name": "get_transcript", "description": "Read a meeting's transcript."],
            ],
            "compatibility": ["platforms": ["darwin"]],
        ]
        return try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Writes `figg.mcpb` into `folder` and returns it.
    public static func write(server: URL, version: String, icon: URL?, into folder: URL) throws -> URL {
        let fm = FileManager.default
        let staging = folder.appendingPathComponent("figg-extension", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try manifest(server: server, version: version).write(to: staging.appendingPathComponent("manifest.json"))
        if let icon, fm.fileExists(atPath: icon.path) {
            try fm.copyItem(at: icon, to: staging.appendingPathComponent("icon.png"))
            try addIcon(to: staging.appendingPathComponent("manifest.json"))
        }
        let bundle = folder.appendingPathComponent("\(name).mcpb")
        try? fm.removeItem(at: bundle)
        // ditto -c -k zips the folder's contents, so manifest.json is at the root.
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--norsrc", staging.path, bundle.path]
        try zip.run()
        zip.waitUntilExit()
        try? fm.removeItem(at: staging)
        guard zip.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Could not make the Claude extension file."])
        }
        return bundle
    }

    private static func addIcon(to manifestURL: URL) throws {
        var m = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any] ?? [:]
        m["icon"] = "icon.png"
        try JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: manifestURL)
    }
}
