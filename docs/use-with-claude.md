# Use your meetings in Claude

figg can let Claude Desktop and Claude Code read the meetings it recorded on
your Mac, so you can ask "Summarise my meetings from last week" or "What did
we decide about the budget?" without copying notes into the chat.

## Connect

Open figg's **Settings**, **Claude** tab. It shows one row each for Claude
Desktop and Claude Code: *Not installed*, a **Connect** button, or
*Connected*.

- **Claude Desktop:** Connect hands Claude an extension file, and Claude
  shows its own Install dialog. Click **Install**, then start a new chat.
  The extension shows as "figg meetings" under Claude's Settings,
  Extensions, where you can switch it off or remove it.
- **Claude Code:** Connect runs `claude mcp add --scope user figg -- <path to
  figg-mcp>`, so every new session can use it. If that fails, the tab shows
  the command to run in a terminal.

After a meeting finishes, figg also shows a card once with the same buttons
if Claude is installed but not connected. **Not now** hides it for good; the
"Suggest connecting Claude after a meeting" switch in the Claude tab (or
`claude.suggest` in config.yaml) brings it back.

## What Claude can do

| Tool | What Claude gets |
|---|---|
| `list_meetings` | Meetings, newest first, with start time in your Mac's time zone, length, status and attendees. A date such as `2026-11-13` means that whole local day. |
| `search_meetings` | figg's full-text search over titles, notes and transcripts, with where each meeting matched. |
| `get_meeting` | One meeting's notes and enhanced notes. |
| `get_meetings` | The same for up to 20 meetings at once, to read a series together. |
| `get_transcript` | The transcript as `[mm:ss] Speaker: text`, in pages of 2000 lines. |

## Privacy

- **Read-only.** The server opens figg's database read-only. Claude cannot
  change or delete a meeting.
- **On this Mac.** Claude starts `figg-mcp` (inside Figg.app) as a local
  process. It opens no port and contacts no service.
- **Text only.** It never reads audio.
- **What Claude reads goes to Anthropic** as part of the conversation, like
  text you paste in. Claude asks before each tool call unless you allow it
  for good.

claude.ai in a browser and the phone app cannot use it: the server runs on
your Mac.

## Set up by hand

The server is `Figg.app/Contents/MacOS/figg-mcp`. Any MCP client that can
start a local (stdio) server can run it with no arguments. `--db <path>` or
`FIGG_DB` points it at another `figg.sqlite`, and `--version` prints figg's
version.

Claude Desktop rewrites `claude_desktop_config.json` from memory while it
runs, so an entry added there by hand only sticks if Claude is quit first.
The extension from the Claude tab avoids that.

## For contributors

`app/Sources/FiggMCP` holds the server (JSON-RPC in `MCPServer`, the tools
in `MCPTools`, the queries in `MeetingLibrary`); `app/Sources/figg-mcp` is
its executable. `app/Sources/FiggClaude` finds Claude and builds the
extension file; `ClaudeConnector` and `ClaudeViews` in `app/Sources/Figg`
are the Settings tab and the card. `app/scripts/bundle.sh` copies
`figg-mcp` into the app and signs it without the app's entitlements.

The server reads the app's schema (`FiggStore`), so a migration that renames
or drops a column it reads shows up as a failing `FiggMCPTests` test.
