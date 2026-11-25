// figg's MCP server. Claude Desktop and Claude Code start it and talk over
// stdin/stdout, one JSON message per line. stdout is the protocol channel,
// so nothing else may be printed there; and meeting text is never logged.
//
// Usage: figg-mcp [--db <path to figg.sqlite>]   (FIGG_DB also sets it)
import FiggMCP
import FiggStore
import Foundation

let arguments = CommandLine.arguments
let path: String = {
    if let i = arguments.firstIndex(of: "--db"), i + 1 < arguments.count { return arguments[i + 1] }
    if let env = ProcessInfo.processInfo.environment["FIGG_DB"], !env.isEmpty { return env }
    return FiggPaths.standard.database.path
}()

if arguments.contains("--version") {
    print(FiggMCPVersion.current)
    exit(0)
}

let server = MCPServer(version: FiggMCPVersion.current) { try MeetingLibrary.openReadOnly(path: path) }
while let line = readLine(strippingNewline: true) {
    if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
    if let reply = server.handle(line: line) {
        FileHandle.standardOutput.write(Data((reply + "\n").utf8))
    }
}
