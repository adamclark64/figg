import AppKit
import FiggExport
import FiggNotes
import FiggStore
import SwiftUI

struct ExportMenu: View {
    let meeting: Meeting
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @State private var showJira = false
    @State private var result: String?

    var body: some View {
        Menu {
            Button("Copy as Markdown") { copy(Formatters.markdown(meeting)) }
            Button("Copy for Slack") { copy(Formatters.slack(meeting)) }
            Divider()
            Button("Publish to Confluence…") { Task { await publish() } }
            Button("Create Jira tickets from action items…") { showJira = true }
                .disabled(ActionItems.parse(meeting.enhancedNotes ?? "").isEmpty)
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .sheet(isPresented: $showJira) {
            JiraSheet(meeting: meeting).environmentObject(settings)
        }
        .alert(result ?? "", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
            Button("OK") { result = nil }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func publish() async {
        guard let config = settings.atlassianConfig else {
            result = "Add your Atlassian site, email and API token in Settings > Sharing first."
            return
        }
        do {
            let url = try await AtlassianClient(config: config).publishToConfluence(meeting)
            NSWorkspace.shared.open(url)
        } catch {
            result = error.localizedDescription
        }
    }
}

struct JiraSheet: View {
    let meeting: Meeting
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var items: [ActionItem] = []
    @State private var chosen: Set<Int> = []
    @State private var working = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create Jira tickets").font(.headline)
            Text("Project \(settings.config.sharing.jiraProject.isEmpty ? "(not set)" : settings.config.sharing.jiraProject), type Task.")
                .foregroundStyle(.secondary)
            List(items) { item in
                Toggle(isOn: Binding(
                    get: { chosen.contains(item.id) },
                    set: { if $0 { chosen.insert(item.id) } else { chosen.remove(item.id) } })) {
                    Text(item.summary)
                }
            }
            .frame(minHeight: 160)
            if let message { Text(message).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                Button("Create \(chosen.count) ticket(s)") { Task { await create() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || working)
            }
        }
        .padding(16)
        .frame(width: 480)
        .onAppear {
            items = ActionItems.parse(meeting.enhancedNotes ?? "")
            chosen = Set(items.filter { !$0.done }.map(\.id))
        }
    }

    private func create() async {
        guard let config = settings.atlassianConfig else {
            message = "Add your Atlassian site, email and API token in Settings > Sharing first."
            return
        }
        working = true
        defer { working = false }
        do {
            let keys = try await AtlassianClient(config: config).createJiraIssues(items.filter { chosen.contains($0.id) }, meeting: meeting)
            message = "Created " + keys.joined(separator: ", ")
            chosen.removeAll()
        } catch {
            message = error.localizedDescription
        }
    }
}
