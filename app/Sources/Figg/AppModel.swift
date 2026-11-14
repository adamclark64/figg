import AppKit
import Combine
import FiggAudio
import FiggCalendar
import FiggConfig
import FiggExport
import FiggLLM
import FiggNotes
import FiggStore
import FiggTranscription
import FiggUpdate
import Foundation
import SwiftUI

struct Banner: Identifiable, Equatable {
    enum Kind { case info, warning, error }
    enum Action: Equatable { case ssoLogin, retryEnhance(String), openPrivacySettings, installUpdate }

    let id = UUID()
    var kind: Kind
    var text: String
    var action: Action?
    var isConfigWarning = false
}

enum ModelState: Equatable {
    case notDownloaded, loading, ready
    case failed(String)
}

/// App-wide state and the meeting pipeline:
/// record → chunk files → transcription queue → store → enhance.
@MainActor
final class AppModel: ObservableObject {
    let settings: AppSettings
    let paths: FiggPaths
    let store: Store

    @Published var meetings: [Meeting] = []
    @Published var searchText = "" { didSet { reloadMeetings() } }
    @Published var selection: SidebarItem? = nil
    @Published var banners: [Banner] = []
    @Published var whisperState: ModelState = .notDownloaded

    /// The meeting being recorded, if any.
    @Published private(set) var recordingId: String?
    @Published private(set) var recordingStarted: Date?
    /// Streaming enhanced text per meeting while Enhance runs.
    @Published var enhancingText: [String: String] = [:]
    /// Latest quick-action output per meeting; nil once dismissed.
    @Published var quickActionResults: [String: QuickActionResult] = [:]
    /// The calendar meeting happening now or next (nil without calendar access).
    @Published private(set) var upcomingEvent: CalendarEvent?
    /// Streaming pre-meeting brief; nil once dismissed.
    @Published var briefResult: BriefResult?
    /// Bumped when transcript lines arrive, so open views refresh.
    @Published private(set) var transcriptVersion = 0

    private var recorder: Recorder?
    private let transcriber: any Transcriber
    private(set) var queue: TranscriptionQueue!
    private var credentialProviders: [String: AWSCLICredentialsProvider] = [:]
    private var notesSaveTasks: [String: Task<Void, Never>] = [:]
    private var pendingNotes: [String: String] = [:]
    private var configWatch: AnyCancellable?
    private var calendarWatch: AnyCancellable?
    private var meetingWatcher: MeetingWatcher?
    private var recordingWidget: RecordingWidget?
    let updates = UpdateManager()
    /// Set when the user chose Update during a recording; installed on stop.
    private var pendingUpdate: ReleaseInfo?
    /// Injectable for tests; EventKit in the app.
    var makeCalendar: () -> any CalendarProvider = { EventKitCalendar() }
    private var calendar: (any CalendarProvider)?
    private var calendarTimer: Timer?

    init(settings: AppSettings, paths: FiggPaths = .standard) {
        self.settings = settings
        self.paths = paths
        var openError: Error?
        do {
            store = try Store(paths: paths)
        } catch {
            // Without a database nothing works; fall back to memory and say so.
            store = try! Store.inMemory()
            openError = error
        }
        let t = settings.config.transcription
        if t.engine.lowercased() == "whisper" {
            transcriber = WhisperKitTranscriber(model: t.model, language: t.language.isEmpty ? nil : t.language, downloadBase: paths.models)
        } else {
            transcriber = ParakeetTranscriber()
        }
        let keepAudio = settings.keepAudio
        queue = TranscriptionQueue(
            store: store,
            paths: paths,
            transcriber: transcriber,
            separator: t.separateSpeakers ? FluidSpeakerSeparator() : nil,
            keepAudio: { keepAudio.value },
            onLines: { [weak self] _ in
                Task { @MainActor in self?.transcriptVersion += 1 }
            })
        // Warn about a broken config.yaml at launch and whenever a reload finds one.
        configWatch = settings.$loadError.removeDuplicates().sink { [weak self] error in
            guard let self else { return }
            self.banners.removeAll { $0.isConfigWarning }
            if let error { self.banners.append(Banner(kind: .warning, text: error, isConfigWarning: true)) }
        }
        if let openError {
            banners.append(Banner(kind: .error, text: "Could not open the figg database: \(openError.localizedDescription). Notes will not be saved."))
        }
        reloadMeetings()
        // The first download is large, so it waits for the user to ask (or to
        // record). If the model is already on disk, load it now.
        Task { if await transcriber.isDownloaded() { await loadWhisper() } }
        Task { await recoverUnfinished() }
        meetingWatcher = MeetingWatcher(model: self, settings: settings)
        meetingWatcher?.start()
        recordingWidget = RecordingWidget(model: self, settings: settings)
        recordingWidget?.start()
        // Set up (or drop) calendar access now and whenever the setting flips.
        calendarWatch = settings.$config.map(\.calendar.enabled).removeDuplicates().sink { [weak self] enabled in
            Task { @MainActor in self?.setCalendarEnabled(enabled) }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await self?.autoCheckForUpdates()
        }
    }

    // MARK: Calendar

    private func setCalendarEnabled(_ enabled: Bool) {
        calendarTimer?.invalidate()
        calendarTimer = nil
        guard enabled else {
            calendar = nil
            upcomingEvent = nil
            return
        }
        let provider = makeCalendar()
        calendar = provider
        Task { [weak self] in
            guard await provider.requestAccess() else {
                await MainActor.run {
                    self?.banners.append(Banner(
                        kind: .warning,
                        text: "figg can't read your calendar. Allow it under System Settings > Privacy & Security > Calendars, or turn the calendar off in figg's settings."))
                }
                return
            }
            await self?.refreshUpcomingEvent()
        }
        calendarTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshUpcomingEvent() }
        }
    }

    /// The event happening now, or the next one in the coming 4 hours.
    func refreshUpcomingEvent() async {
        guard let calendar else { return }
        let now = Date()
        let events = await calendar.events(from: now.addingTimeInterval(-4 * 3600), to: now.addingTimeInterval(4 * 3600))
        upcomingEvent = events.current(at: now) ?? events.next(after: now)
    }

    /// Titles the meeting and records attendees from the calendar event
    /// running right now, so speakers can be named and notes titled.
    private func applyCalendarContext(to id: String) async {
        guard let calendar else { return }
        let now = Date()
        let events = await calendar.events(from: now.addingTimeInterval(-4 * 3600), to: now.addingTimeInterval(3600))
        guard let event = events.current(at: now) else { return }
        try? store.update(meetingId: id) {
            if $0.title.isEmpty { $0.title = event.title }
            $0.attendees = event.attendees
            $0.calendarEventId = event.id
        }
        reloadMeetings()
    }

    // MARK: Services

    /// Built from the active `llm.providers` entry on every use, so a change
    /// in Settings or config.yaml applies to the next request.
    var llm: LLMProvider {
        let entry = settings.config.llm.active
        switch entry.kind {
        case FiggConfig.LLM.Provider.bedrockKind:
            let profile = settings.config.aws.profile
            let creds = credentialProviders[profile] ?? AWSCLICredentialsProvider(profile: profile)
            credentialProviders[profile] = creds
            return BedrockProvider(region: settings.config.aws.region, credentials: creds)
        case FiggConfig.LLM.Provider.openAIKind:
            return OpenAICompatibleProvider(name: entry.name, baseURL: entry.baseURL, apiKey: settings.apiKey(for: entry.id))
        default:
            return UnavailableProvider(message: "config.yaml: provider \"\(entry.id)\" has kind \"\(entry.kind)\". Use \"bedrock\" or \"openai\".")
        }
    }

    /// Model IDs belong to the active provider.
    private var models: ModelChoice {
        let m = settings.config.llm.active.models
        return ModelChoice(notesModel: m.notes, fastModel: m.resolvedFast)
    }

    var enhancer: Enhancer { Enhancer(llm: llm, models: models) }

    var chat: NotesChat { NotesChat(store: store, llm: llm, model: models.notesModel) }

    func loadWhisper() async {
        guard whisperState != .loading, whisperState != .ready else { return }
        whisperState = .loading
        do {
            try await transcriber.load()
            whisperState = .ready
        } catch {
            whisperState = .failed(error.localizedDescription)
        }
    }

    // MARK: Meetings

    func reloadMeetings() {
        meetings = (try? searchText.isEmpty ? store.allMeetings() : store.searchMeetings(searchText)) ?? []
    }

    func meeting(_ id: String) -> Meeting? { try? store.meeting(id: id) }

    func transcript(_ id: String) -> [TranscriptLine] { (try? store.transcript(meetingId: id)) ?? [] }

    func newMeeting() -> Meeting {
        let m = Meeting(status: .needsEnhance)
        try? store.save(m)
        reloadMeetings()
        selection = .meeting(m.id)
        return m
    }

    func rename(_ id: String, to title: String) {
        try? store.update(meetingId: id) { $0.title = title }
        reloadMeetings()
    }

    /// Debounced so typing doesn't write on every keystroke.
    func saveNotes(_ id: String, _ text: String) {
        pendingNotes[id] = text
        notesSaveTasks[id]?.cancel()
        notesSaveTasks[id] = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            flushNotes(id)
        }
    }

    /// Writes notes still waiting in the debounce window.
    func flushNotes(_ id: String) {
        notesSaveTasks[id]?.cancel()
        notesSaveTasks[id] = nil
        guard let text = pendingNotes.removeValue(forKey: id) else { return }
        try? store.updateNotes(meetingId: id, userNotes: text)
    }

    /// nil = auto. Used by the final pass, so set it before pressing Stop.
    func setRoomSpeakers(_ id: String, _ count: Int?) {
        try? store.update(meetingId: id) { $0.roomSpeakers = count }
    }

    /// nil = the configured default template.
    func setTemplate(_ id: String, _ templateId: String?) {
        try? store.update(meetingId: id) { $0.template = templateId }
        reloadMeetings()
    }

    /// The template Enhance will use for this meeting.
    func template(for meeting: Meeting) -> NoteTemplate {
        NoteTemplate.named(meeting.template ?? settings.config.notes.template)
    }

    func saveEnhanced(_ id: String, _ text: String) {
        try? store.update(meetingId: id) { $0.enhancedNotes = text }
    }

    /// Ticks or unticks the checkbox on one line of the saved enhanced notes.
    /// `line` is the `NoteLine.id` the view rendered. Ignored while Enhance
    /// is streaming: that text is not saved yet and replaces the notes when
    /// it finishes.
    func toggleCheckbox(_ id: String, line: Int) {
        guard enhancingText[id] == nil, let notes = meeting(id)?.enhancedNotes else { return }
        let toggled = Checkboxes.toggle(notes, line: line)
        if toggled != notes { saveEnhanced(id, toggled) }
    }

    /// Renames a displayed speaker across this meeting's transcript.
    func renameSpeaker(_ id: String, from: String, to: String) {
        try? store.renameSpeaker(meetingId: id, from: from, to: to)
        transcriptVersion += 1
    }

    func delete(_ id: String) {
        if recordingId == id { return }
        try? store.delete(meetingId: id)
        try? FileManager.default.removeItem(at: paths.meetingDir(id))
        if selection == .meeting(id) { selection = nil }
        reloadMeetings()
    }

    // MARK: Recording

    var isRecording: Bool { recordingId != nil }

    /// Live levels for the recording strip. Not @Published: the waveform
    /// polls it, so 20 updates a second never redraw the rest of the app.
    var levelMeter: LevelMeter? { recorder?.levels }

    func toggleRecording() {
        Task {
            if isRecording { await stopRecording() } else { await startRecording() }
        }
    }

    func startRecording() async {
        guard !isRecording else { return }
        if whisperState == .notDownloaded {
            Task { await loadWhisper() }
            banners.append(Banner(kind: .info, text: "Downloading the speech model. Audio is saved meanwhile and is transcribed once the download finishes."))
        }
        let meeting = Meeting(status: .recording)
        try? store.save(meeting)
        let id = meeting.id
        let queue = self.queue!
        silenceWatch = SilenceWatch()
        let recorder = Recorder(dir: paths.pendingDir(id)) { [weak self] chunk in
            let peak = chunk.stream == .system ? chunk.peak() : 1
            Task { await queue.enqueue(chunk, meetingId: id) }
            Task { @MainActor in self?.checkSystemSilence(peak: peak) }
        }
        let result = await recorder.start()
        for problem in result.problems {
            banners.append(Banner(kind: result.anyStarted ? .warning : .error, text: problem, action: .openPrivacySettings))
        }
        guard result.anyStarted else {
            try? store.delete(meetingId: id)
            reloadMeetings()
            return
        }
        self.recorder = recorder
        recordingId = id
        recordingStarted = Date()
        selection = .meeting(id)
        reloadMeetings()
        await applyCalendarContext(to: id)
    }

    private var silenceWatch = SilenceWatch()

    private func checkSystemSilence(peak: Float) {
        guard silenceWatch.record(peak: peak) else { return }
        banners.append(Banner(
            kind: .warning,
            text: "figg hasn't heard any sound from your Mac for 30 seconds. If people are talking on the call, give figg System Audio Recording permission (Privacy & Security > Screen & System Audio Recording), then quit and reopen figg.",
            action: .openPrivacySettings))
    }

    func stopRecording() async {
        guard let id = recordingId, let recorder else { return }
        recorder.stop()
        self.recorder = nil
        recordingId = nil
        recordingStarted = nil
        try? store.update(meetingId: id) {
            $0.endedAt = Date()
            $0.status = .transcribing
        }
        flushNotes(id)
        reloadMeetings()
        await finishTranscription(id)
        await enhance(id)
        // Last, so a relaunch never discards the final pass or enhancement.
        // A new recording may have started during the final pass; leave the
        // update pending so that recording's own stop picks it up.
        if !isRecording, let release = pendingUpdate {
            pendingUpdate = nil
            startInstall(release)
        }
    }

    /// Drains the live queue, then re-transcribes the whole recording for
    /// accuracy. If that final pass fails, the live transcript is kept.
    private func finishTranscription(_ id: String) async {
        await queue.enqueuePending(meetingId: id)
        await queue.drain()
        do {
            try await queue.finalPass(meetingId: id, roomSpeakers: meeting(id)?.roomSpeakers)
        } catch {
            NSLog("figg: final transcription pass failed for %@: %@", id, String(describing: error))
            banners.append(Banner(kind: .warning, text: "Couldn't re-check the full transcript (\(error.localizedDescription)). The live transcript was kept."))
        }
        transcriptVersion += 1
    }

    /// Meetings left in `recording`/`transcribing`/`enhancing` by a crash or
    /// quit: transcribe what is on disk and leave them ready for Enhance.
    private func recoverUnfinished() async {
        guard let unfinished = try? store.unfinishedMeetings(), !unfinished.isEmpty else { return }
        for m in unfinished where m.id != recordingId {
            try? store.update(meetingId: m.id) {
                $0.status = .transcribing
                $0.endedAt = $0.endedAt ?? Date()
            }
            await finishTranscription(m.id)
            try? store.updateStatus(meetingId: m.id, .needsEnhance, error: "Recovered after figg quit during this meeting. Press Enhance to finish.")
        }
        reloadMeetings()
        banners.append(Banner(kind: .info, text: "Recovered \(unfinished.count) unfinished meeting(s)."))
    }

    // MARK: Enhance

    func enhance(_ id: String) async {
        flushNotes(id)
        await finishTranscription(id)  // picks up chunks a failed run left behind
        guard let meeting = meeting(id) else { return }
        let lines = transcript(id)
        if meeting.userNotes.isEmpty && lines.isEmpty {
            try? store.updateStatus(meetingId: id, .needsEnhance, error: "Nothing to enhance yet: no notes and no transcript.")
            reloadMeetings()
            return
        }
        try? store.updateStatus(meetingId: id, .enhancing)
        reloadMeetings()
        let enhancer = self.enhancer
        do {
            if meeting.title.isEmpty, let title = try? await enhancer.suggestTitle(meeting: meeting, transcript: lines), !title.isEmpty {
                rename(id, to: title)
            }
            var final = ""
            for try await text in enhancer.enhance(meeting: meeting, transcript: lines, template: template(for: meeting)) {
                final = text
                enhancingText[id] = text
            }
            try? store.update(meetingId: id) {
                $0.enhancedNotes = final
                $0.status = .ready
                $0.errorMessage = nil
            }
        } catch {
            let message = error.localizedDescription
            try? store.updateStatus(meetingId: id, .needsEnhance, error: message)
            let action: Banner.Action = (error as? LLMError).map { if case .authExpired = $0 { return .ssoLogin } else { return .retryEnhance(id) } } ?? .retryEnhance(id)
            banners.append(Banner(kind: .error, text: message, action: action))
        }
        enhancingText[id] = nil
        reloadMeetings()
    }

    // MARK: Quick actions

    struct QuickActionResult: Equatable {
        var action: QuickAction
        var text: String
        var running: Bool
        var error: String?
    }

    /// Generates one quick-action document and streams it into
    /// `quickActionResults[id]` for the meeting view's sheet.
    func runQuickAction(_ id: String, _ action: QuickAction) async {
        flushNotes(id)
        guard let meeting = meeting(id) else { return }
        let lines = transcript(id)
        quickActionResults[id] = QuickActionResult(action: action, text: "", running: true)
        do {
            var final = ""
            for try await text in enhancer.run(action, meeting: meeting, transcript: lines) {
                final = text
                quickActionResults[id] = QuickActionResult(action: action, text: text, running: true)
            }
            quickActionResults[id] = QuickActionResult(action: action, text: final, running: false)
        } catch {
            quickActionResults[id] = QuickActionResult(action: action, text: "", running: false, error: error.localizedDescription)
        }
    }

    // MARK: Pre-meeting brief

    struct BriefResult: Equatable {
        var eventTitle: String
        var text: String
        var running: Bool
        var error: String?
    }

    /// Streams a prep brief for the upcoming event into `briefResult`.
    func runBrief() async {
        guard let event = upcomingEvent else { return }
        briefResult = BriefResult(eventTitle: event.title, text: "", running: true)
        let brief = MeetingBrief(store: store, llm: llm, model: models.notesModel)
        do {
            var final = ""
            let (stream, _) = try brief.brief(title: event.title, attendees: event.attendees, start: event.start)
            for try await text in stream {
                final = text
                briefResult = BriefResult(eventTitle: event.title, text: text, running: true)
            }
            briefResult = BriefResult(eventTitle: event.title, text: final, running: false)
        } catch {
            briefResult = BriefResult(eventTitle: event.title, text: "", running: false, error: error.localizedDescription)
        }
    }

    // MARK: Banner actions

    func perform(_ action: Banner.Action) {
        switch action {
        case .ssoLogin:
            runSSOLogin()
        case let .retryEnhance(id):
            Task { await enhance(id) }
        case .openPrivacySettings:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        case .installUpdate:
            installUpdate()
        }
    }

    /// Launch-time check: silent unless a newer release exists.
    func autoCheckForUpdates() async {
        guard settings.config.updates.autoCheck else { return }
        guard let release = await updates.check(quietly: true) else { return }
        banners.append(Banner(kind: .info,
                              text: "figg v\(release.version) is available.",
                              action: .installUpdate))
    }

    /// Never relaunch mid-recording; remember the choice and install on stop.
    func installUpdate() {
        guard case let .available(release) = updates.phase else { return }
        if isRecording {
            pendingUpdate = release
            banners.append(Banner(kind: .info, text: "The update will install after you stop recording."))
            return
        }
        startInstall(release)
    }

    /// The download takes a while, so recording state is re-checked just before
    /// the relaunch: if a recording began meanwhile, the new build stays on disk
    /// and the user restarts when ready.
    private func startInstall(_ release: ReleaseInfo) {
        Task {
            let relaunched = await updates.downloadAndInstall(release, canRelaunch: { !self.isRecording })
            if case let .failed(message) = updates.phase {
                banners.append(Banner(kind: .error, text: message))
            }
            if !relaunched, updates.phase == .idle {
                banners.append(Banner(kind: .info, text: "figg v\(release.version) is installed. Restart figg after your recording to use it."))
            }
        }
    }

    /// Runs `aws sso login` for the configured profile, which opens the
    /// browser. Profiles with static keys never need it.
    func runSSOLogin() {
        guard let cli = AWSCLICredentialsProvider.findCLI() else {
            banners.append(Banner(kind: .error, text: "The AWS CLI was not found. Install it with `brew install awscli`."))
            return
        }
        let profile = settings.config.aws.profile
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["sso", "login", "--profile", profile]
        process.terminationHandler = { [weak self] p in
            Task { @MainActor in
                guard let self else { return }
                await self.credentialProviders[profile]?.invalidate()
                self.banners.append(Banner(
                    kind: p.terminationStatus == 0 ? .info : .error,
                    text: p.terminationStatus == 0 ? "Signed in to AWS as profile \(profile)." : "AWS sign-in did not complete."))
            }
        }
        try? process.run()
    }

    func dismiss(_ banner: Banner) {
        banners.removeAll { $0.id == banner.id }
    }

    static let consentSnippet = "Heads up: I'm using figg to transcribe this call for my notes. The audio stays on my Mac and isn't recorded to the cloud."

    func copyConsentSnippet() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.consentSnippet, forType: .string)
    }
}

enum SidebarItem: Hashable {
    case ask
    case meeting(String)
}
