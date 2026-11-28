import FiggClaude
import SwiftUI

private let privacyNote = "Claude can list, search and read your meetings, notes and transcripts on this Mac. It cannot change them and never gets audio. What Claude reads goes to Anthropic as part of the chat, like text you paste in."

/// Settings, Claude: connect Claude Desktop and Claude Code to figg's
/// meetings.
struct ClaudeSettings: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var model: AppModel

    var body: some View {
        ClaudeSettingsForm(connector: model.claude, suggest: $settings.config.claude.suggest)
    }
}

/// Observes the connector directly: views that only watch AppModel do not
/// redraw when a nested object changes.
private struct ClaudeSettingsForm: View {
    @ObservedObject var connector: ClaudeConnector
    @Binding var suggest: Bool

    private var canConnect: Bool { connector.server != nil }

    var body: some View {
        Form {
            Section {
                ClaudeAppRow(name: "Claude Desktop", link: connector.status.desktop, canConnect: canConnect) {
                    connector.connectDesktop()
                }
                ClaudeAppRow(name: "Claude Code", link: connector.status.code, canConnect: canConnect) {
                    connector.connectCode()
                }
                if let message = connector.message {
                    Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let command = connector.codeCommand {
                    HStack {
                        Text(command).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
                        Button("Copy") { connector.copyCodeCommand() }.controlSize(.small)
                    }
                }
            } header: {
                Text("Let Claude read your meetings")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(privacyNote)
                    if connector.server == nil {
                        Text("This build has no figg-mcp beside it. Build figg with app/scripts/bundle.sh to connect.")
                            .foregroundStyle(.orange)
                    }
                    Text("Then ask Claude things like \"Summarise my meetings from last week\" or \"What did we decide about the budget?\"")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Suggest connecting Claude after a meeting", isOn: $suggest)
        }
        .onAppear { connector.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            connector.refresh()
        }
    }
}

private struct ClaudeAppRow: View {
    let name: String
    let link: ClaudeLink
    let canConnect: Bool
    let connect: () -> Void

    var body: some View {
        HStack {
            Text(name)
            Spacer()
            state
        }
    }

    @ViewBuilder private var state: some View {
        switch link {
        case .notInstalled:
            Text("Not installed").foregroundStyle(.secondary)
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .notConnected:
            if canConnect {
                Button("Connect", action: connect)
            } else {
                Text("Not connected").foregroundStyle(.secondary)
            }
        }
    }
}

/// Shown once under a finished meeting's header when Claude is installed
/// but not connected. "Not now" turns it off for good (claude.suggest in
/// config.yaml); Settings, Claude turns it back on.
struct ClaudeSuggestionCard: View {
    @ObservedObject var connector: ClaudeConnector
    let dismiss: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        if connector.server != nil, connector.status.canSuggest {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.title3).foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ask Claude about your meetings").font(.headline).foregroundStyle(theme.ink)
                    Text(privacyNote).font(.callout).foregroundStyle(theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    if let message = connector.message {
                        Text(message).font(.callout).foregroundStyle(theme.ink)
                    }
                    HStack {
                        if connector.status.desktop == .notConnected {
                            Button("Connect Claude Desktop") { connector.connectDesktop() }
                                .buttonStyle(.borderedProminent)
                        }
                        if connector.status.code == .notConnected {
                            Button("Add to Claude Code") { connector.connectCode() }
                        }
                        Button("Not now", action: dismiss).buttonStyle(.borderless)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
