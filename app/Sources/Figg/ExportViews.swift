import AppKit
import FiggExport
import FiggNotes
import FiggStore
import SwiftUI
import UniformTypeIdentifiers

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
            Button("Save as Markdown…") { save() }
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

    /// Saves the notes and transcript as a .md file the user picks. Reads
    /// the store directly (not `model.transcript`, which hides errors) so a
    /// failed read never saves a file without its transcript.
    @MainActor
    private func save() {
        let lines: [TranscriptLine]
        do {
            lines = try model.store.transcript(meetingId: meeting.id)
        } catch {
            result = "Could not read the transcript: \(error.localizedDescription)"
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ExportFile.suggestedName(for: meeting, pathExtension: "md")
        panel.allowedContentTypes = UTType(filenameExtension: "md", conformingTo: .plainText).map { [$0] } ?? [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ExportFile.write(MarkdownExport.document(meeting, lines: lines), to: url)
        } catch {
            result = "Could not save the file: \(error.localizedDescription)"
        }
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
