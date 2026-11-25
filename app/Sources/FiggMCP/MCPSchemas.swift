import Foundation

/// What `tools/list` returns: names, descriptions and JSON Schemas.
enum MCPSchemas {
    private static let limit: [String: Any] = [
        "type": "integer", "minimum": 1, "maximum": 200, "description": "Most meetings to return (default 20).",
    ]

    private static func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var o: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        if !required.isEmpty { o["required"] = required }
        return o
    }

    private static func tool(_ name: String, _ title: String, _ description: String, _ schema: [String: Any]) -> [String: Any] {
        [
            "name": name, "title": title, "description": description, "inputSchema": schema,
            "annotations": [
                "title": title, "readOnlyHint": true, "destructiveHint": false,
                "idempotentHint": true, "openWorldHint": false,
            ],
        ]
    }

    static let tools: [[String: Any]] = [
        tool("list_meetings", "List figg meetings",
             "List meetings recorded in figg, newest first: id, title, start in the Mac's local time, length, status, "
                 + "and attendees when figg matched a calendar event. Use the id with get_meeting(s) or get_transcript.",
             object([
                 "limit": limit,
                 "offset": ["type": "integer", "minimum": 0, "description": "Meetings to skip, to page through (default 0)."],
                 "since": ["type": "string", "description": "Only meetings that started on or after this. A date (2026-11-13) means that local day; or an ISO 8601 time."],
                 "until": ["type": "string", "description": "Only meetings that started on or before this. A date (2026-11-13) includes that whole local day."],
             ])),
        tool("search_meetings", "Search figg meetings",
             "Full-text search over meeting titles, notes and transcripts. Every word must match (as a word prefix). "
                 + "Newest first, each with where it matched and an excerpt.",
             object(["query": ["type": "string", "description": "Words to find."], "limit": limit], required: ["query"])),
        tool("get_meeting", "Read a figg meeting's notes",
             "A meeting's details, the notes the user typed, and the enhanced notes figg wrote from the transcript. "
                 + "Use get_meetings for several at once, and get_transcript for what was said word for word.",
             object(["id": ["type": "string", "description": "Meeting id from list_meetings or search_meetings."]], required: ["id"])),
        tool("get_meetings", "Read several figg meetings' notes",
             "Notes for up to \(MCPTools.maxBatch) meetings in one call, in the order given, each as get_meeting shows it. "
                 + "Use this to read a series of meetings together.",
             object(["ids": [
                 "type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": MCPTools.maxBatch,
                 "description": "Meeting ids from list_meetings or search_meetings.",
             ]], required: ["ids"])),
        tool("get_transcript", "Read a figg meeting's transcript",
             "The meeting's transcript, one line per utterance as `[mm:ss] Speaker: text` (`[h:mm:ss]` past the first hour). "
                 + "\"Me\" is the person using figg. Long transcripts come in pages; the last line says whether there is more.",
             object([
                 "id": ["type": "string", "description": "Meeting id."],
                 "offset": ["type": "integer", "minimum": 0, "description": "Lines to skip (default 0)."],
                 "limit": ["type": "integer", "minimum": 1, "maximum": 5000, "description": "Most lines to return (default 2000)."],
             ], required: ["id"])),
    ]
}
