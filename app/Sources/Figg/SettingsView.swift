import FiggConfig
import FiggNotes
import FiggStore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading) {
            if let error = settings.loadError {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            tabs
            HStack {
                Text("Saved to \(settings.configURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Show config.yaml") { settings.revealConfig() }.controlSize(.small)
                Button("Reload") { settings.reload() }.controlSize(.small)
            }
        }
        .frame(width: 540)
        .padding(20)
    }

    private var tabs: some View {
        TabView {
            AISettings().tabItem { Label("AI", systemImage: "sparkles") }
            RecordingSettings().tabItem { Label("Recording", systemImage: "waveform") }
            SharingSettings().tabItem { Label("Sharing", systemImage: "square.and.arrow.up") }
        }
    }
}

struct AISettings: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var model: AppModel

    /// Profiles from config.yaml, plus the current one if it was typed there by hand.
    private var profileChoices: [String] {
        let p = settings.config.aws.profiles
        return p.contains(settings.config.aws.profile) ? p : p + [settings.config.aws.profile]
    }

    private typealias Provider = FiggConfig.LLM.Provider

    private var provider: Provider { settings.config.llm.active }
    private var isBedrock: Bool { provider.kind == Provider.bedrockKind }

    /// Selects by the entry actually in use, so an id in config.yaml that
    /// matches nothing still shows a real choice.
    private var providerID: Binding<String> {
        Binding(get: { provider.id }, set: { settings.config.llm.provider = $0 })
    }

    private var apiKey: Binding<String> {
        let id = provider.id
        return Binding(get: { settings.apiKey(for: id) }, set: { settings.setAPIKey($0, for: id) })
    }

    private var providerFooter: String {
        if isBedrock {
            return "figg calls Claude on AWS Bedrock through the AWS CLI, with the AWS profile you pick here. Bedrock usage is billed to your AWS account. Only text is sent (notes, transcript, questions), never audio."
        }
        let key = provider.id == Provider.openRouter.id ? " Create a key at openrouter.ai/keys." : ""
        return "figg sends your notes, transcript and questions as text to \(provider.name) and whichever model it routes to. Free models may log or train on that text, so think twice before using them for confidential meetings. Audio never leaves your Mac. The API key is stored in the macOS Keychain.\(key)"
    }

    private var modelsCaption: String {
        if isBedrock {
            return "Bedrock inference-profile IDs. Haiku is the cheap default; us.anthropic.claude-sonnet-5-5 writes better notes at about 20x the cost."
        }
        if provider.id == Provider.openRouter.id {
            return "openrouter/free picks a free model for you. Any ID from openrouter.ai/models works; free ones end in :free."
        }
        return "Model IDs as \(provider.name) names them."
    }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: providerID) {
                    ForEach(settings.config.llm.providers) { Text($0.name).tag($0.id) }
                }
                if isBedrock {
                    Picker("AWS profile", selection: $settings.config.aws.profile) {
                        ForEach(profileChoices, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Region", text: $settings.config.aws.region)
                    Button("Sign in to AWS") { model.runSSOLogin() }
                } else {
                    TextField("Base URL", text: $settings.config.llm.active.baseURL)
                    SecureField("API key", text: apiKey)
                }
            } footer: {
                Text(providerFooter).foregroundStyle(.secondary)
            }
            Section("Models") {
                TextField("Notes and chat", text: $settings.config.llm.active.models.notes)
                TextField("Titles (fast)", text: $settings.config.llm.active.models.fast)
                if let shipped = Provider.builtIn(id: provider.id) {
                    Button("Reset to defaults") { settings.config.llm.active.models = shipped.models }
                }
                Text(modelsCaption).font(.caption).foregroundStyle(.secondary)
            }
            Section("Notes") {
                Picker("Default template", selection: $settings.config.notes.template) {
                    ForEach(NoteTemplate.all) { t in Text(t.name).tag(t.id) }
                }
                Text("Shapes the sections Enhance writes. Each meeting can pick its own template in the meeting view.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct RecordingSettings: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Picker("Theme", selection: $settings.config.appearance.theme) {
                Text("fig (warm paper)").tag("fig")
                Text("System").tag("system")
            }
            Toggle("Offer to record when a meeting app uses the mic", isOn: $settings.config.detection.enabled)
            Text("Works with any app (Zoom, Teams, Meet in a browser, Slack huddles). Dictation apps like FluidVoice and Wispr Flow are ignored; add others under detection.ignore_apps in config.yaml.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Use your calendar (titles, attendees, pre-meeting brief)", isOn: $settings.config.calendar.enabled)
            Text("Read-only and local: figg titles new recordings after the current event, suggests attendee names for speakers, and can brief you before a meeting from past notes. macOS asks for Calendar access the first time.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Show a floating widget while recording in another app", isOn: $settings.config.recording.widget)
            Text("A small pill on the edge of the screen shows that figg is listening while you are in the meeting app. Click the fig to return to the note or the camera to copy a screenshot; drag it anywhere.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Keep audio after transcription", isOn: $settings.config.recording.keepAudio)
            Text("Off by default. When on, audio chunks are kept under ~/Library/Application Support/figg/meetings.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Speech engine", selection: $settings.config.transcription.engine) {
                Text("Parakeet (Nvidia, recommended)").tag("parakeet")
                Text("Whisper").tag("whisper")
            }
            Toggle("Tell different speakers apart (Me, Guest 1, Them 2...)", isOn: $settings.config.transcription.separateSpeakers)
            TextField("Whisper model", text: $settings.config.transcription.model)
                .disabled(settings.config.transcription.engine != "whisper")
            TextField("Language", text: $settings.config.transcription.language)
            Text("Engine and model changes take effect after restarting figg. Language applies to Whisper (empty = detect); Parakeet detects it. Smaller models (e.g. `small.en`) are faster on older Macs.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Use headphones: on laptop speakers your mic also hears the other side, so some of their speech can show up as \"Me\".")
                .font(.caption).foregroundStyle(.secondary)
            Section("Updates") {
                Toggle("Check for updates at launch", isOn: $settings.config.updates.autoCheck)
                HStack {
                    Button("Check for Updates…") { Task { await model.updates.check(quietly: false) } }
                    UpdateStatusView(updates: model.updates, install: model.installUpdate)
                }
                Text("\(UpdateManager.currentVersion.map { "figg v\($0)" } ?? "figg (dev build)"). Updates come from figg's download site; only an anonymous version check is sent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Observes UpdateManager directly: RecordingSettings only watches AppModel,
/// which does not republish when a nested object's phase changes.
private struct UpdateStatusView: View {
    @ObservedObject var updates: UpdateManager
    let install: () -> Void

    var body: some View {
        switch updates.phase {
        case .idle: EmptyView()
        case .checking: FigLoadingLabel(text: "Checking…")
        case .upToDate: Text("You're up to date.").foregroundStyle(.secondary)
        case let .available(release): Button("Update to v\(release.version)", action: install)
        case .downloading: FigLoadingLabel(text: "Downloading…", progress: updates.downloadProgress)
        case .installing: FigLoadingLabel(text: "Installing…")
        case let .failed(message): Text(message).foregroundStyle(.orange)
        }
    }
}

struct SharingSettings: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            TextField("Atlassian site", text: $settings.config.sharing.atlassianSite, prompt: Text("https://your-site.atlassian.net"))
            TextField("Email", text: $settings.atlassianEmail)
            SecureField("API token", text: $settings.atlassianToken)
            Link("Create an API token", destination: URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!)
                .font(.caption)
            TextField("Confluence space key", text: $settings.config.sharing.confluenceSpace)
            TextField("Jira project key", text: $settings.config.sharing.jiraProject)
            Text("Email and API token are stored in your macOS Keychain, not in config.yaml.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
