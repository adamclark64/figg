import Foundation

/// Just enough MCP (JSON-RPC 2.0, one message per line over stdio) for a
/// tools-only server: initialize, ping, tools/list, tools/call.
/// Spec: modelcontextprotocol.io.
public struct MCPServer: Sendable {
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    let version: String
    let tools: MCPTools
    /// Opened per tool call, so a missing database (figg never run) is a
    /// tool error rather than a server that will not start, and each call
    /// sees meetings saved since the last one.
    let openLibrary: @Sendable () throws -> MeetingLibrary

    public init(version: String, tools: MCPTools = MCPTools(), openLibrary: @escaping @Sendable () throws -> MeetingLibrary) {
        self.version = version
        self.tools = tools
        self.openLibrary = openLibrary
    }

    /// Answers one line of input with one line of output, or nil when no
    /// reply is due (a notification, or a response from the client).
    public func handle(line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data) else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let msg = any as? [String: Any], let method = msg["method"] as? String else { return nil }
        let id = msg["id"]
        let params = msg["params"] as? [String: Any] ?? [:]

        func reply(_ result: [String: Any]) -> String? {
            guard let id else { return nil }
            return encode(["jsonrpc": "2.0", "id": id, "result": result])
        }

        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            return reply([
                "protocolVersion": Self.supportedVersions.contains(asked) ? asked : Self.supportedVersions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "figg", "title": "figg meetings", "version": version],
                "instructions": "Read-only access to the user's figg meetings on this Mac: titles, notes, enhanced notes "
                    + "and transcripts. Find meetings with list_meetings or search_meetings, then read them with "
                    + "get_meeting, get_meetings and get_transcript.",
            ])
        case "ping":
            return reply([:])
        case "tools/list":
            return reply(["tools": MCPSchemas.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let result: MCPTools.Result
            do {
                result = tools.call(name, args, library: try openLibrary())
            } catch {
                result = .init(text: "Could not open figg's database: \(error)", isError: true)
            }
            var body: [String: Any] = ["content": [["type": "text", "text": result.text]]]
            if result.isError { body["isError"] = true }
            return reply(body)
        default:
            guard let id else { return nil }
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    private func encode(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
