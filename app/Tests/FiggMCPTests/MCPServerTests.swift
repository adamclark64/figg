@testable import FiggMCP
import FiggStore
import Foundation
import GRDB
import Testing

@Suite struct MCPServerTests {
    private func json(_ line: String?) throws -> [String: Any] {
        let data = try #require(line?.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func server() throws -> MCPServer {
        let f = try Fixture()
        return MCPServer(version: "1.2.3", tools: f.tools) { f.library }
    }

    @Test func handshakeListsReadOnlyTools() throws {
        let s = try server()
        let initialize = try json(s.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#))
        let result = try #require(initialize["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect((result["serverInfo"] as? [String: Any])?["version"] as? String == "1.2.3")

        #expect(s.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)

        let list = try json(s.handle(line: #"{"jsonrpc":"2.0","id":"two","method":"tools/list"}"#))
        #expect(list["id"] as? String == "two")
        let tools = try #require((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["list_meetings", "search_meetings", "get_meeting", "get_meetings", "get_transcript"])
        for tool in tools {
            #expect((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true)
        }
    }

    @Test func unknownVersionGetsTheNewest() throws {
        let reply = try json(try server().handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
        #expect((reply["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-11-25")
    }

    @Test func toolCallsReturnTextContent() throws {
        let reply = try json(try server().handle(line: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_meetings","arguments":{"query":"compost"}}}"#))
        let result = try #require(reply["result"] as? [String: Any])
        #expect(result["isError"] == nil)
        let content = try #require(result["content"] as? [[String: Any]])
        #expect((content.first?["text"] as? String)?.contains(Fixture.planning) == true)
    }

    @Test func errorsAndJunk() throws {
        let s = try server()
        #expect(try json(s.handle(line: "not json"))["error"] != nil)
        #expect(s.handle(line: #"{"jsonrpc":"2.0","id":9,"result":{}}"#) == nil, "a client response gets no reply")
        let unknown = try json(s.handle(line: #"{"jsonrpc":"2.0","id":4,"method":"resources/list"}"#))
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(try json(s.handle(line: #"{"jsonrpc":"2.0","id":5,"method":"ping"}"#))["result"] as? [String: Any] != nil)
    }

    @Test func missingDatabaseIsAToolError() throws {
        let s = MCPServer(version: "0") { try MeetingLibrary.openReadOnly(path: "/nonexistent/figg.sqlite") }
        let reply = try json(s.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_meetings","arguments":{}}}"#))
        let result = try #require(reply["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        #expect(text.contains("Record a meeting in figg first"))
    }

    @Test func openedReadOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try Store(paths: FiggPaths(base: dir))
        try store.save(Meeting(title: "Kept"))
        let library = try MeetingLibrary.openReadOnly(path: FiggPaths(base: dir).database.path)
        #expect(throws: (any Error).self) {
            try (library.db as! DatabaseQueue).write { try $0.execute(sql: "DELETE FROM meeting") }
        }
        #expect(try library.list(limit: 5, offset: 0, since: nil, until: nil).total == 1)
    }
}
