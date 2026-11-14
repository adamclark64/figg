import FiggConfig
import Foundation
import Testing

@Suite struct ConfigTests {
    @Test func defaultValues() {
        let c = FiggConfig()
        #expect(c.aws.profile == "default")
        #expect(c.aws.profiles == ["default"])
        #expect(c.sharing.atlassianSite.isEmpty)
        #expect(c.llm.provider == "bedrock")
        #expect(c.llm.active.models.notes == "us.anthropic.claude-haiku-5-5")
        #expect(c.transcription.engine == "parakeet")
        #expect(c.detection.enabled)
        #expect(c.appearance.theme == "fig")
        #expect(c.updates.autoCheck)
        #expect(c.feedback.bugReportEndpoint.isEmpty)
        #expect(c.recording.widget)
        #expect(c.recording.widgetPosition == nil)
    }

    @Test func roundTripsThroughWrittenYAML() throws {
        var c = FiggConfig()
        c.aws.profile = "other"
        c.llm.active.models.notes = "us.anthropic.claude-sonnet-5-5"
        c.llm.provider = "openrouter"
        c.llm.active.models.fast = "google/gemma-4-31b-it:free"
        c.llm.providers.append(.init(id: "local", name: "My \"local\" box", kind: "openai",
                                     baseURL: "http://localhost:1234/v1", models: .init(notes: "qwen", fast: "")))
        c.recording.keepAudio = true
        c.recording.widget = false
        c.recording.widgetPosition = .init(x: 1380, y: -212.5)
        c.sharing.jiraProject = "PROJ"
        c.transcription.engine = "whisper"
        c.detection.enabled = false
        c.transcription.separateSpeakers = false
        c.detection.ignoreApps = ["com.example.app"]
        c.appearance.theme = "system"
        c.appearance.loader = "fig"
        c.notes.template = "standup"
        c.sharing.confluenceSpace = "has \"quotes\" and \\ slash"
        c.updates.autoCheck = false
        c.feedback.bugReportEndpoint = "https://relay.example.com/api/bug-report"
        #expect(try FiggConfig.parse(c.yaml()) == c)
    }

    @Test func reportingABugNeedsNoSetup() throws {
        // A default file says nothing about feedback or a relay.
        #expect(!FiggConfig().yaml().contains("feedback"))
        #expect(!FiggConfig().yaml().contains("relay"))
        // A relay set by hand is read, written back as its own section, and
        // leaves the sections round it in place.
        var c = try FiggConfig.parse("feedback:\n  bug_report_endpoint: https://relay.example.com/api/bug-report\n")
        #expect(c.feedback.bugReportEndpoint == "https://relay.example.com/api/bug-report")
        let yaml = c.yaml()
        #expect(yaml.contains("\n\nfeedback:\n"))
        #expect(yaml.contains("\n  bug_report_endpoint: \"https://relay.example.com/api/bug-report\"\n\nappearance:\n"))
        #expect(try FiggConfig.parse(yaml) == c)
        // "browser" (no relay) is kept like any other value.
        c = try FiggConfig.parse("feedback:\n  bug_report_endpoint: browser\n")
        #expect(c.feedback.bugReportEndpoint == "browser")
        #expect(try FiggConfig.parse(c.yaml()) == c)
        // An empty value left in an older file reads as unset and goes.
        c = try FiggConfig.parse("feedback:\n  bug_report_endpoint: \"\"\n")
        #expect(c.feedback.bugReportEndpoint.isEmpty)
        #expect(!c.yaml().contains("feedback"))
    }

    /// Files from before `llm:` kept Bedrock model IDs in a top-level block.
    @Test func legacyModelsBlockMovesToBedrock() throws {
        let c = try FiggConfig.parse("""
        models:
          notes: us.anthropic.claude-sonnet-5-5
        """)
        #expect(c.llm.provider == "bedrock")
        #expect(c.llm.active.models.notes == "us.anthropic.claude-sonnet-5-5")
        #expect(c.llm.active.models.fast == "us.anthropic.claude-haiku-5-5")
        #expect(c.llm.providers.map(\.id) == ["bedrock", "openrouter"])
        #expect(c.aws.profile == "default")
        // Once rewritten in the new shape, the choice survives.
        #expect(try FiggConfig.parse(c.yaml()) == c)
        #expect(!c.yaml().contains("\nmodels:"))
    }

    @Test func llmSectionWinsOverLegacyModels() throws {
        let c = try FiggConfig.parse("""
        llm:
          provider: openrouter
        models:
          notes: us.anthropic.claude-sonnet-5-5
        """)
        #expect(c.llm.active == .openRouter)
        #expect(c.llm.providers == FiggConfig.LLM.Provider.builtIn)
    }

    @Test func openRouterDefaultsToTheFreeRouter() {
        let p = FiggConfig.LLM.Provider.openRouter
        #expect(p.kind == "openai")
        #expect(p.baseURL == "https://openrouter.ai/api/v1")
        #expect(p.models.notes == "openrouter/free")
    }

    @Test func providerEntriesNeedOnlyAnId() throws {
        let c = try FiggConfig.parse("""
        llm:
          provider: groq
          providers:
            - id: openrouter
              models:
                notes: "google/gemma-4-31b-it:free"
            - id: groq
              base_url: https://api.groq.com/openai/v1
              models:
                notes: some-model
        """)
        // A built-in id fills the gaps from the shipped entry.
        #expect(c.llm.providers[0].baseURL == "https://openrouter.ai/api/v1")
        #expect(c.llm.providers[0].models.notes == "google/gemma-4-31b-it:free")
        #expect(c.llm.providers[0].models.fast == "openrouter/free")
        // Anything else is an OpenAI-compatible service named after its id.
        #expect(c.llm.active.id == "groq")
        #expect(c.llm.active.name == "groq")
        #expect(c.llm.active.kind == "openai")
        #expect(c.llm.active.models.fast.isEmpty)
        #expect(c.llm.active.models.resolvedFast == "some-model")
        // The file's list is the whole list.
        #expect(c.llm.providers.count == 2)
    }

    @Test func unknownOrEmptyProviderChoiceStillWorks() throws {
        let typo = try FiggConfig.parse("llm:\n  provider: nope")
        #expect(typo.llm.active.id == "bedrock")
        let empty = try FiggConfig.parse("llm:\n  providers: []")
        #expect(empty.llm.providers == FiggConfig.LLM.Provider.builtIn)
        #expect(throws: (any Error).self) { try FiggConfig.parse("llm:\n  providers:\n    - name: no id") }
    }

    @Test func editingTheActiveProviderLeavesOthersAlone() {
        var c = FiggConfig()
        c.llm.provider = "openrouter"
        c.llm.active.models.notes = "x:free"
        #expect(c.llm.providers[1].models.notes == "x:free")
        #expect(c.llm.providers[0] == .bedrock)
    }

    @Test func theFigLoaderIsAHiddenOption() throws {
        // The default is the fig newton, and a default file does not mention the key.
        #expect(FiggConfig().appearance.loader == "newton")
        #expect(!FiggConfig().yaml().contains("loader"))
        #expect(try FiggConfig.parse("appearance:\n  theme: system\n").appearance.loader == "newton")
        // Set by hand, it is read, and it survives figg rewriting the file.
        var c = try FiggConfig.parse("appearance:\n  loader: fig\n")
        #expect(c.appearance.loader == "fig")
        #expect(c.appearance.theme == "fig")
        #expect(c.yaml().contains("  loader: \"fig\""))
        #expect(try FiggConfig.parse(c.yaml()) == c)
        // Back to the default, the line goes again. So does a `newton` line
        // someone added while the fig was the default (0.6.0).
        c.appearance.loader = "newton"
        #expect(!c.yaml().contains("loader"))
    }

    @Test func updatesSectionIsOptional() throws {
        let c = try FiggConfig.parse("updates: {}")
        #expect(c.updates.autoCheck)
    }

    @Test func emptyFileIsDefaults() throws {
        #expect(try FiggConfig.parse("  \n# just a comment\n") == FiggConfig())
    }

    @Test func badYAMLThrows() {
        #expect(throws: (any Error).self) { try FiggConfig.parse("aws: [unclosed") }
        #expect(throws: (any Error).self) { try FiggConfig.parse("recording:\n  keep_audio: maybe") }
    }

    @Test func savesAndLoadsFromDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/config.yaml")
        var c = FiggConfig()
        c.aws.region = "us-east-2"
        try c.save(to: url)
        #expect(try FiggConfig.load(from: url) == c)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("# figg settings"))
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test func missingFileIsDefaults() throws {
        #expect(try FiggConfig.load(from: URL(fileURLWithPath: "/nonexistent/figg/config.yaml")) == FiggConfig())
    }

    /// Files written before the widget existed keep it on, in the default spot.
    @Test func widgetKeysAreOptional() throws {
        let c = try FiggConfig.parse("recording:\n  keep_audio: true")
        #expect(c.recording.keepAudio)
        #expect(c.recording.widget)
        #expect(c.recording.widgetPosition == nil)
        #expect(FiggConfig().yaml().contains("widget_position: null"))
    }

    /// The position is figg's own bookkeeping: one it cannot read means the
    /// default spot, not a broken config.
    @Test func unreadableWidgetPositionFallsBackToTheDefaultSpot() throws {
        let c = try FiggConfig.parse("recording:\n  widget: false\n  widget_position: { x: left }")
        #expect(!c.recording.widget)
        #expect(c.recording.widgetPosition == nil)
        #expect(try FiggConfig.parse("recording:\n  widget_position: [3, 4]").recording.widgetPosition == nil)
    }

    @Test func secretsNeverWritten() {
        let yaml = FiggConfig().yaml().lowercased()
        #expect(!yaml.contains("token:"))
        #expect(!yaml.contains("email:"))
        #expect(!yaml.contains("key:"))
    }
}
