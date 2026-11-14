import Foundation
import Yams

/// Everything a user can set, stored in `~/.config/figg/config.yaml`.
/// Secrets (Atlassian login, model provider API keys) are never in this
/// file; they live in the Keychain. Missing keys fall back to the defaults
/// below, so a partial file is fine.
public struct FiggConfig: Codable, Equatable, Sendable {
    public var llm = LLM()
    public var aws = AWS()
    public var notes = Notes()
    public var transcription = Transcription()
    public var recording = Recording()
    public var detection = Detection()
    public var calendar = Calendar()
    public var sharing = Sharing()
    public var feedback = Feedback()
    public var appearance = Appearance()
    public var updates = Updates()

    public init() {}

    public struct AWS: Codable, Equatable, Sendable {
        public init() {}
        /// AWS profiles (from ~/.aws/config) shown in the Settings picker.
        public var profiles = ["default"]
        public var profile = "default"
        public var region = "us-east-1"
    }

    /// Where the language model comes from. Providers are a list so a new
    /// source is a config entry; each keeps its own model IDs, so switching
    /// provider never means retyping them.
    public struct LLM: Codable, Equatable, Sendable {
        public init() {}
        /// Id of the entry in `providers` that answers Enhance, chat and titles.
        public var provider = Provider.bedrock.id
        public var providers = Provider.builtIn

        /// The selected entry. An id that matches nothing falls back to the
        /// first entry, so a typo degrades to a working provider.
        public var active: Provider {
            get { providers.first { $0.id == provider } ?? providers.first ?? .bedrock }
            set {
                guard let i = providers.firstIndex(where: { $0.id == newValue.id }) else { return }
                providers[i] = newValue
            }
        }

        public struct Provider: Codable, Equatable, Sendable, Identifiable {
            /// Claude on AWS Bedrock, signed in through the `aws:` section.
            public static let bedrockKind = "bedrock"
            /// Any OpenAI-compatible chat-completions API.
            public static let openAIKind = "openai"

            /// Stable key: selects the entry and names its Keychain item.
            public var id: String
            /// Shown in Settings and in error messages.
            public var name: String
            public var kind: String
            /// API root for `openai` entries, e.g. https://openrouter.ai/api/v1.
            public var baseURL: String
            public var models: Models

            public init(id: String, name: String, kind: String, baseURL: String = "", models: Models) {
                self.id = id
                self.name = name
                self.kind = kind
                self.baseURL = baseURL
                self.models = models
            }

            public static let bedrock = Provider(id: "bedrock", name: "AWS Bedrock", kind: bedrockKind, models: Models())
            /// "openrouter/free" lets OpenRouter pick a free model, which
            /// outlives any single free model ID (those come and go).
            public static let openRouter = Provider(
                id: "openrouter", name: "OpenRouter", kind: openAIKind,
                baseURL: "https://openrouter.ai/api/v1",
                models: Models(notes: "openrouter/free", fast: "openrouter/free"))
            public static let builtIn = [bedrock, openRouter]

            /// The shipped entry with this id, if any (for defaults and reset).
            public static func builtIn(id: String) -> Provider? { builtIn.first { $0.id == id } }

            enum CodingKeys: String, CodingKey {
                case id, name, kind, models
                case baseURL = "base_url"
            }
        }
    }

    public struct Models: Codable, Equatable, Sendable {
        public init() {}
        public init(notes: String, fast: String) {
            self.notes = notes
            self.fast = fast
        }
        /// Enhanced notes and chat. The Bedrock default is Haiku, the cheap
        /// one; us.anthropic.claude-sonnet-5-5 writes better notes at ~20x the cost.
        public var notes = "us.anthropic.claude-haiku-5-5"
        /// Meeting titles.
        public var fast = "us.anthropic.claude-haiku-5-5"
        /// The titles model, or the notes model when none is set.
        public var resolvedFast: String { fast.isEmpty ? notes : fast }
    }

    public struct Notes: Codable, Equatable, Sendable {
        public init() {}
        /// Default note template id for new meetings ("notes", "one-on-one",
        /// "standup", "interview", "customer-call", "brainstorm", "planning").
        /// Each meeting can pick its own in the meeting view.
        public var template = "notes"
    }

    public struct Transcription: Codable, Equatable, Sendable {
        public init() {}
        /// "parakeet" (Nvidia Parakeet TDT v3, default) or "whisper".
        public var engine = "parakeet"
        /// Tell apart several people on one stream (in the room, or on the call).
        public var separateSpeakers = true
        /// WhisperKit model name; only used when engine is "whisper".
        public var model = "large-v3-v20240930_turbo"
        /// Spoken language code, or empty to let Whisper detect it.
        public var language = "en"
        enum CodingKeys: String, CodingKey {
            case engine, model, language
            case separateSpeakers = "separate_speakers"
        }
    }

    public struct Recording: Codable, Equatable, Sendable {
        public init() {}
        public var keepAudio = false
        /// Show the floating pill while recording with another app in front.
        public var widget = true
        /// Where the user last dragged the pill; nil means the default spot
        /// (right edge, centred). Written by figg, not meant for hand edits.
        public var widgetPosition: WidgetPosition?
        enum CodingKeys: String, CodingKey {
            case keepAudio = "keep_audio"
            case widget
            case widgetPosition = "widget_position"
        }

        /// Bottom-left corner of the widget panel in screen points, measured
        /// the AppKit way (from the bottom-left of the primary display).
        public struct WidgetPosition: Codable, Equatable, Sendable {
            public var x: Double
            public var y: Double
            public init(x: Double, y: Double) {
                self.x = x
                self.y = y
            }
        }
    }

    public struct Detection: Codable, Equatable, Sendable {
        public init() {}
        /// Offer to record when another app starts using the microphone.
        public var enabled = true
        /// Extra bundle IDs to ignore, on top of figg's built-in list of
        /// dictation apps (FluidVoice, Wispr Flow, Siri, macOS dictation).
        public var ignoreApps: [String] = []
        enum CodingKeys: String, CodingKey {
            case enabled
            case ignoreApps = "ignore_apps"
        }
    }

    public struct Calendar: Codable, Equatable, Sendable {
        public init() {}
        /// Read the macOS calendar (read-only, local) to title meetings, list
        /// attendees for speaker naming, and offer a pre-meeting brief.
        public var enabled = false
    }

    public struct Sharing: Codable, Equatable, Sendable {
        public init() {}
        public var atlassianSite = ""
        public var confluenceSpace = ""
        public var jiraProject = ""
        enum CodingKeys: String, CodingKey {
            case atlassianSite = "atlassian_site"
            case confluenceSpace = "confluence_space"
            case jiraProject = "jira_project"
        }
    }

    public struct Feedback: Codable, Equatable, Sendable {
        public init() {}
        /// Where Report a Bug sends reports. Empty is the default and needs no
        /// setup: figg's hosted relay files the issue. A URL is a relay you
        /// host yourself (api/ in the repo, deployed on Vercel); "browser"
        /// opens the report as a GitHub issue in your browser instead. Not a
        /// secret: a relay holds its GitHub token server-side. Resolved by
        /// `BugReportRelay.endpoint(forSetting:)`. Like the loader, this is a
        /// hidden option: the section is only written to config.yaml once
        /// someone has set it by hand.
        public var bugReportEndpoint = ""
        enum CodingKeys: String, CodingKey {
            case bugReportEndpoint = "bug_report_endpoint"
        }
    }

    public struct Appearance: Codable, Equatable, Sendable {
        public init() {}
        /// "fig" (warm paper and plum, from the logo) or "system" (stock macOS colours).
        public var theme = "fig"
        /// The loading indicator: "newton" (the hopping fig newton) or "fig"
        /// (the spinning fig). The fig is a hidden option: it has no control
        /// in Settings and its line is only written to config.yaml once
        /// someone has set it by hand.
        public var loader = "newton"
    }

    public struct Updates: Codable, Equatable, Sendable {
        public init() {}
        /// Once per launch, ask figg's download site (anonymously) whether a
        /// newer release exists. Only a version check; nothing is sent.
        public var autoCheck = true
        enum CodingKeys: String, CodingKey { case autoCheck = "auto_check" }
    }

    /// `$FIGG_CONFIG` if set, else `~/.config/figg/config.yaml`.
    public static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["FIGG_CONFIG"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/figg/config.yaml")
    }

    public static func parse(_ yaml: String) throws -> FiggConfig {
        // Empty or comment-only files are an empty document, not an error.
        guard try Yams.compose(yaml: yaml) != nil else { return FiggConfig() }
        return try YAMLDecoder().decode(FiggConfig.self, from: yaml)
    }

    /// Loads the file, or returns defaults if it does not exist yet.
    public static func load(from url: URL = defaultURL) throws -> FiggConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return FiggConfig() }
        return try parse(String(contentsOf: url, encoding: .utf8))
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try yaml().write(to: url, atomically: true, encoding: .utf8)
    }

    /// The file as figg writes it: every key, with comments. Rewritten whole
    /// on each save, so comments you add yourself are not kept.
    public func yaml() -> String {
        func q(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        // The loader line is left out while it is the default, so the fig
        // stays a hidden option.
        let loaderLine = appearance.loader == Appearance().loader ? "" : "\n  loader: \(q(appearance.loader))"
        // Reporting a bug needs no setup, so the feedback section is left out
        // unless someone has set it by hand.
        let feedbackSection = feedback.bugReportEndpoint.isEmpty ? "" : """

            feedback:
              # Where Report a Bug sends reports: a relay you host (api/ in the
              # repo), e.g. https://<your-relay>.vercel.app/v1/bug-report (not a
              # secret; the GitHub token lives on the relay), or "browser" to
              # open the report as a GitHub issue in your browser. Without this
              # section, figg's own relay files the issue.
              bug_report_endpoint: \(q(feedback.bugReportEndpoint))

            """
        // Each line carries its own indentation: text interpolated into the
        // literal below is not re-indented.
        let providers = llm.providers.map { p in
            var lines = [
                "    - id: \(q(p.id))",
                "      name: \(q(p.name))",
                "      kind: \(q(p.kind))",
            ]
            if p.kind != LLM.Provider.bedrockKind { lines.append("      base_url: \(q(p.baseURL))") }
            lines += [
                "      models:",
                "        notes: \(q(p.models.notes))",
                "        fast: \(q(p.models.fast))",
            ]
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
        return """
        # figg settings. Edit here or in figg > Settings (the app rewrites this file).
        # figg reloads it when the app comes to the front.
        # Secrets (Atlassian login, model provider API keys) are kept in the macOS Keychain, not here.

        llm:
          # Which entry under providers writes notes, chat answers and titles.
          provider: \(q(llm.provider))
          # Model sources. Add an entry to use another service. kind is "bedrock"
          # (Claude on AWS, signed in through the aws: section below) or "openai"
          # (any OpenAI-compatible chat API: OpenRouter, OpenAI, Groq...).
          # Type the API key for an "openai" entry in Settings > AI.
          # models.notes writes notes and chat; models.fast writes meeting titles.
          #
          # bedrock: inference-profile IDs. List yours with:
          #   aws bedrock list-inference-profiles --profile <name> --query "inferenceProfileSummaries[].inferenceProfileId"
          #   Haiku is cheapest; us.anthropic.claude-sonnet-5-5 writes better notes at ~20x the cost.
          # openrouter: "openrouter/free" picks a free model for you. Any ID from
          #   https://openrouter.ai/models works; free ones end in ":free".
          #   Free models may log or train on the text figg sends them.
          providers:
        \(providers)

        aws:
          # Used by the bedrock provider. Profiles from ~/.aws/config, with
          # access keys or SSO. An SSO profile logs in with:
          #   aws sso login --profile <name>
          profiles: [\(aws.profiles.map(q).joined(separator: ", "))]
          profile: \(q(aws.profile))
          region: \(q(aws.region))

        notes:
          # Default template for enhanced notes: notes, one-on-one, standup,
          # interview, customer-call, brainstorm or planning. Each meeting can
          # override this in the meeting view.
          template: \(q(notes.template))

        transcription:
          # "parakeet" (Nvidia Parakeet TDT v3: fastest and most accurate in testing)
          # or "whisper". Changes take effect after restarting figg.
          engine: \(q(transcription.engine))
          # Label different people on the same stream: "Me", "Guest 1"... in the room,
          # "Them 1", "Them 2"... on the call. Runs once, after you press Stop.
          separate_speakers: \(transcription.separateSpeakers)
          # WhisperKit model name, used only when engine is "whisper".
          model: \(q(transcription.model))
          # Spoken language code for Whisper; "" lets it detect. Parakeet detects automatically.
          language: \(q(transcription.language))

        recording:
          # Keep audio chunks after transcription (default: delete them).
          keep_audio: \(recording.keepAudio)
          # Show a small floating pill while figg records and another app is in
          # front: live levels, and a click on the fig returns to the note.
          widget: \(recording.widget)
          # Where you last dragged the pill (figg writes this). null puts it back
          # on the right edge of the screen.
          widget_position: \(recording.widgetPosition.map { "{ x: \($0.x), y: \($0.y) }" } ?? "null")

        detection:
          # Offer to record when another app (Zoom, Teams, Meet in a browser...) starts using the mic.
          enabled: \(detection.enabled)
          # Extra bundle IDs to never prompt for. Dictation apps (FluidVoice, Wispr Flow,
          # Siri) are already ignored. Find an app's ID with: osascript -e 'id of app "Name"'
          ignore_apps: [\(detection.ignoreApps.map(q).joined(separator: ", "))]

        calendar:
          # Read your macOS calendar (locally, read-only) to title meetings, suggest
          # attendee names for speakers, and offer a pre-meeting brief. Asks for
          # Calendar access the first time it is turned on.
          enabled: \(calendar.enabled)

        sharing:
          # e.g. https://your-site.atlassian.net
          atlassian_site: \(q(sharing.atlassianSite))
          confluence_space: \(q(sharing.confluenceSpace))
          jira_project: \(q(sharing.jiraProject))
        \(feedbackSection)
        appearance:
          # "fig" (warm paper and plum, from the logo) or "system" (stock macOS colours).
          theme: \(q(appearance.theme))\(loaderLine)

        updates:
          # Once per launch, check figg's download site for a newer release
          # (anonymous; nothing about you or your meetings is sent). Update
          # from Settings.
          auto_check: \(updates.autoCheck)

        """
    }
}

// MARK: Lenient decoding: any missing key keeps its default.

extension FiggConfig {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        llm = try c.decodeIfPresent(LLM.self, forKey: .llm) ?? LLM()
        // Files written before `llm:` kept the Bedrock model IDs in a
        // top-level `models:` block. Carry them over so an upgrade does not
        // quietly reset a chosen model.
        if !c.contains(.llm),
           let old = try decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(Models.self, forKey: .models),
           let i = llm.providers.firstIndex(where: { $0.id == LLM.Provider.bedrock.id }) {
            llm.providers[i].models = old
        }
        aws = try c.decodeIfPresent(AWS.self, forKey: .aws) ?? AWS()
        notes = try c.decodeIfPresent(Notes.self, forKey: .notes) ?? Notes()
        transcription = try c.decodeIfPresent(Transcription.self, forKey: .transcription) ?? Transcription()
        recording = try c.decodeIfPresent(Recording.self, forKey: .recording) ?? Recording()
        detection = try c.decodeIfPresent(Detection.self, forKey: .detection) ?? Detection()
        calendar = try c.decodeIfPresent(Calendar.self, forKey: .calendar) ?? Calendar()
        sharing = try c.decodeIfPresent(Sharing.self, forKey: .sharing) ?? Sharing()
        feedback = try c.decodeIfPresent(Feedback.self, forKey: .feedback) ?? Feedback()
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? Appearance()
        updates = try c.decodeIfPresent(Updates.self, forKey: .updates) ?? Updates()
    }
}

extension FiggConfig {
    /// Top-level keys figg no longer writes but still reads.
    private enum LegacyKeys: String, CodingKey { case models }
}

extension FiggConfig.LLM {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? d.provider
        // The file's list is the whole list: deleting an entry removes it.
        // An empty list would leave nothing to talk to, so it means defaults.
        let listed = try c.decodeIfPresent([Provider].self, forKey: .providers) ?? d.providers
        providers = listed.isEmpty ? d.providers : listed
    }
}

extension FiggConfig.LLM.Provider {
    private enum ModelKeys: String, CodingKey { case notes, fast }

    /// Only `id` is required. A built-in id fills the rest from the shipped
    /// entry; any other id is assumed to be an OpenAI-compatible service.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        let d = Self.builtIn(id: id)
            ?? Self(id: id, name: id, kind: Self.openAIKind, models: FiggConfig.Models(notes: "", fast: ""))
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? d.kind
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? d.baseURL
        models = d.models
        if c.contains(.models) {
            let m = try c.nestedContainer(keyedBy: ModelKeys.self, forKey: .models)
            models.notes = try m.decodeIfPresent(String.self, forKey: .notes) ?? d.models.notes
            models.fast = try m.decodeIfPresent(String.self, forKey: .fast) ?? d.models.fast
        }
    }
}

extension FiggConfig.AWS {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        profiles = try c.decodeIfPresent([String].self, forKey: .profiles) ?? d.profiles
        profile = try c.decodeIfPresent(String.self, forKey: .profile) ?? d.profile
        region = try c.decodeIfPresent(String.self, forKey: .region) ?? d.region
    }
}

extension FiggConfig.Models {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? d.notes
        fast = try c.decodeIfPresent(String.self, forKey: .fast) ?? d.fast
    }
}

extension FiggConfig.Notes {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        template = try c.decodeIfPresent(String.self, forKey: .template) ?? Self().template
    }
}

extension FiggConfig.Transcription {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? d.engine
        separateSpeakers = try c.decodeIfPresent(Bool.self, forKey: .separateSpeakers) ?? d.separateSpeakers
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
    }
}

extension FiggConfig.Recording {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        keepAudio = try c.decodeIfPresent(Bool.self, forKey: .keepAudio) ?? d.keepAudio
        widget = try c.decodeIfPresent(Bool.self, forKey: .widget) ?? d.widget
        // figg's own bookkeeping, not a setting: a value it cannot read means
        // the default spot, not a config error.
        widgetPosition = (try? c.decodeIfPresent(WidgetPosition.self, forKey: .widgetPosition)) ?? nil
    }
}

extension FiggConfig.Detection {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        ignoreApps = try c.decodeIfPresent([String].self, forKey: .ignoreApps) ?? d.ignoreApps
    }
}

extension FiggConfig.Calendar {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? Self().enabled
    }
}

extension FiggConfig.Sharing {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        atlassianSite = try c.decodeIfPresent(String.self, forKey: .atlassianSite) ?? d.atlassianSite
        confluenceSpace = try c.decodeIfPresent(String.self, forKey: .confluenceSpace) ?? d.confluenceSpace
        jiraProject = try c.decodeIfPresent(String.self, forKey: .jiraProject) ?? d.jiraProject
    }
}

extension FiggConfig.Feedback {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bugReportEndpoint = try c.decodeIfPresent(String.self, forKey: .bugReportEndpoint) ?? Self().bugReportEndpoint
    }
}

extension FiggConfig.Appearance {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? Self().theme
        loader = try c.decodeIfPresent(String.self, forKey: .loader) ?? Self().loader
    }
}

extension FiggConfig.Updates {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoCheck = try c.decodeIfPresent(Bool.self, forKey: .autoCheck) ?? Self().autoCheck
    }
}
