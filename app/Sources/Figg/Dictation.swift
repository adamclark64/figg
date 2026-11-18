import AVFoundation
import AppKit
import Combine
import FiggAudio
import FiggConfig
import FiggDictation
import FiggMeetingApps
import FiggStore
import FiggTranscription
import SwiftUI

/// System-wide dictation: hold the shortcut key in any app, speak, release.
/// The words are transcribed on this Mac and typed where the cursor is; the
/// clipboard is never touched. Every dictation is kept in the history so its
/// text can be copied when it did not land in the right place.
@MainActor
final class DictationController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening
        case transcribing
        /// Finished: the text, and what happened to it.
        case done(DictationOutcome)
        /// A short note shown in the panel, e.g. why nothing was inserted.
        case note(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var history: [Dictation] = []
    /// What has been heard so far, updated about once a second while
    /// listening, then the final text.
    @Published private(set) var liveText = ""
    /// The app that was in front when the key went down: where the text goes.
    @Published private(set) var target: NSRunningApplication?
    /// The pointer is over the panel, so it stays up.
    /// A tap locked recording on; the next press of the key finishes.
    @Published private(set) var handsFree = false
    @Published var hovering = false

    private let store: Store
    private let transcriber: any Transcriber
    private let settings: AppSettings
    private let capture = DictationCapture()
    private let sounds = DictationSounds()
    /// Seconds at the start of this recording to silence: how long the
    /// start cue played into it can be heard. Zero when none played.
    private var startCueSeconds = 0.0
    private var holdToTalk = HoldToTalk(key: .fn)
    private var monitors: [Any] = []
    private var pasteLastHotKey: HotKey?
    private var configWatch: AnyCancellable?
    private var pill: DictationPill?
    private var hideTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var historyWindow: NSWindow?
    private var capturing = false
    /// Key events are ignored until then: while and just after figg types.
    private var ignoreKeysUntil = Date.distantPast
    private static let ownPID = Int64(ProcessInfo.processInfo.processIdentifier)
    /// Bumped by Esc, so a transcription already running does not type.
    private var generation = 0

    init(store: Store, transcriber: any Transcriber, settings: AppSettings) {
        self.store = store
        self.transcriber = transcriber
        self.settings = settings
        reloadHistory()
        configWatch = settings.$config.map(\.dictation).removeDuplicates().sink { [weak self] d in
            Task { @MainActor in self?.apply(d) }
        }
    }

    var level: Float { capture.level }

    // MARK: Turning on and off

    private func apply(_ config: FiggConfig.Dictation) {
        removeMonitors()
        pasteLastHotKey = nil
        guard config.enabled else { return }
        if let combo = KeyCombo(setting: config.pasteLastShortcut) {
            let hotKey = HotKey(combo) { [weak self] in
                MainActor.assumeIsolated { self?.pasteLast() }
            }
            NSLog("figg dictation: paste-last shortcut %@ %@", combo.label, hotKey.registered ? "registered" : "refused by macOS")
            pasteLastHotKey = hotKey.registered ? hotKey : nil
        }
        // Without Accessibility the global monitor hears nothing; macOS's own
        // prompt adds figg to the list (shown once per app).
        if !AccessibilityAccess.isGranted { AccessibilityAccess.request() }
        holdToTalk = HoldToTalk(key: HoldKey(setting: config.key))
        // Global monitors see other apps' events; they need Accessibility.
        // Local monitors cover figg's own windows.
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
            return e
        }) { monitors.append(local) }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if capturing { cancel() }
    }

    // MARK: Keys

    private func handle(_ event: NSEvent) {
        // The keystrokes figg types, and anything macOS sends while it types
        // (it can re-send a still-held modifier), are not the user's.
        if let cg = event.cgEvent, cg.getIntegerValueField(.eventSourceUnixProcessID) == Self.ownPID { return }
        if Date() < ignoreKeysUntil { return }
        let result: HoldToTalk.Event?
        switch event.type {
        case .flagsChanged:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isFn = holdToTalk.key == .fn
            // Right Option shares .option with Left Option; the key code says
            // which one changed, so .option is not counted as "other" for it.
            let keyIsDown = flags.contains(isFn ? .function : .option)
            let others = flags.intersection([.shift, .control, .option, .command]).subtracting(isFn ? [] : .option)
            result = holdToTalk.flagsChanged(keyCode: event.keyCode, keyIsDown: keyIsDown, otherModifiers: !others.isEmpty)
        case .keyDown:
            result = holdToTalk.keyDown(keyCode: event.keyCode)
            // Esc after the key is up: drop a dictation still being
            // transcribed, or just close the panel.
            if result == nil, event.keyCode == HoldToTalk.escapeKeyCode { dismiss() }
        default:
            result = nil
        }
        if let result { NSLog("figg dictation: key event %@ (phase %@)", "\(result)", "\(phase)") }
        switch result {
        case .start: start()
        case .handsFree: handsFree = true
        case .stop: stop()
        case .cancel: cancel()
        case nil: break
        }
    }

    // MARK: Recording

    private func start() {
        guard !capturing else { return }
        guard AVCaptureAuthorized.mic else {
            Task { _ = await DictationCapture.requestPermission() }
            _ = holdToTalk.cancel()
            show(.note("figg needs microphone access to dictate"))
            return
        }
        do {
            try capture.start()
            capturing = true
            handsFree = false
            target = NSWorkspace.shared.frontmostApplication
            liveText = ""
            // After the mic is on, so the first word is never lost; the
            // cue's own moment is silenced in `heard`.
            startCueSeconds = play(.start)?.muteSeconds ?? 0
            show(.listening)
            startLivePreview()
        } catch {
            _ = holdToTalk.cancel()
            show(.note("Could not start the microphone"))
        }
    }

    /// Transcribes what has been heard so far about once a second, so the
    /// words appear while the user speaks. Parakeet takes a fraction of a
    /// second for a few seconds of audio; one pass at a time.
    private func startLivePreview() {
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                guard let self, self.capturing, await self.transcriber.isDownloaded() else { continue }
                let samples = self.heard(self.capture.snapshot())
                guard samples.count > 8_000, !SilenceGate.isSilent(samples) else { continue }
                guard let segments = try? await self.transcriber.transcribe(samples: samples),
                      !Task.isCancelled, self.capturing else { continue }
                self.liveText = DictationText.prepare(segments.compactMap { TranscriptCleaner.clean($0.text) })
            }
        }
    }

    private func cancel() {
        guard capturing else {
            if phase == .listening { show(.idle) }
            return
        }
        liveTask?.cancel()
        _ = capture.stop()
        capturing = false
        handsFree = false
        generation += 1
        play(.cancel)
        show(.idle)
    }

    /// Esc with nothing recording: a dictation still transcribing is dropped
    /// (nothing typed, nothing saved), and the panel closes.
    private func dismiss() {
        guard phase != .idle else { return }
        generation += 1
        show(.idle)
    }

    private func stop() {
        guard capturing else {
            if phase == .listening { show(.idle) }
            return
        }
        liveTask?.cancel()
        let samples = heard(capture.stop())
        capturing = false
        handsFree = false
        // Under half a second of audio, or silence: nothing was said.
        guard samples.count > 8_000, !SilenceGate.isSilent(samples) else {
            play(.cancel)
            show(.idle)
            return
        }
        play(.stop)
        show(.transcribing)
        let run = generation
        Task { await finish(samples, run: run) }
    }

    private func finish(_ samples: [Float], run: Int) async {
        guard await transcriber.isDownloaded() else {
            show(.note("Download the speech model in figg first"))
            return
        }
        let segments: [TranscriptSegment]
        do {
            segments = try await transcriber.transcribe(samples: samples)
        } catch {
            show(.note("Could not transcribe: \(error.localizedDescription)"))
            return
        }
        let (_, element) = TextInserter.focusedField()
        let text = DictationText.prepare(
            segments.compactMap { TranscriptCleaner.clean($0.text) },
            precedingCharacter: TextInserter.precedingCharacter(element))
        guard !text.isEmpty else {
            show(.idle)
            return
        }
        // Esc was pressed while this was transcribing.
        guard run == generation else { return }
        // A new dictation started while this one was transcribing: still
        // type this one, but leave the panel to the new one.
        let quiet = capturing
        if !quiet { liveText = text.trimmingCharacters(in: .whitespaces) }
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let outcome = insert(text, showResult: !quiet)
        NSLog("figg dictation: %@ %d characters into %@", "\(outcome)", text.count, appName)
        let saved = Dictation(text: text.trimmingCharacters(in: .whitespaces), appName: appName, outcome: outcome)
        _ = try? store.addDictation(saved, keep: settings.config.dictation.historyLimit)
        reloadHistory()
    }

    /// Inserts and shows the result in the panel.
    @discardableResult
    private func insert(_ text: String, showResult: Bool = true) -> DictationOutcome {
        ignoreKeysUntil = .distantFuture
        let result = TextInserter.insert(text)
        ignoreKeysUntil = Date().addingTimeInterval(0.4)
        let outcome: DictationOutcome
        let shown: Phase
        switch result {
        // Text is in: the panel goes straight away.
        case .inserted: (outcome, shown) = (.inserted, .idle)
        case .typed: (outcome, shown) = (.typed, .idle)
        case .notInserted(let reason): (outcome, shown) = (.notInserted, .note(Self.message(for: reason)))
        }
        if showResult { show(shown) }
        return outcome
    }

    // MARK: Sounds

    /// Plays a cue when sounds are on. Returns the sound it played.
    @discardableResult
    private func play(_ cue: DictationCue) -> DictationSound? {
        let config = settings.config.dictation
        guard config.sounds, config.soundVolume > 0,
              let sound = cue.sound(setting: Self.soundSetting(cue, config)) else { return nil }
        sounds.play(sound, volume: cue.volume(setting: config.soundVolume))
        return sound
    }

    /// Plays a cue with the current Settings choices, for trying them out
    /// (even with sounds turned off).
    func preview(_ cue: DictationCue) {
        let config = settings.config.dictation
        guard let sound = cue.sound(setting: Self.soundSetting(cue, config)) else { return }
        sounds.play(sound, volume: cue.volume(setting: config.soundVolume))
    }

    static func soundSetting(_ cue: DictationCue, _ config: FiggConfig.Dictation) -> String {
        switch cue {
        case .start: return config.startSound
        case .stop: return config.stopSound
        case .cancel: return config.cancelSound
        }
    }

    /// The mic samples with the start cue silenced, so a speaker playing it
    /// is never transcribed as speech.
    private func heard(_ samples: [Float]) -> [Float] {
        DictationCue.silencingStart(samples, seconds: startCueSeconds)
    }

    // MARK: Actions (the panel's menu)

    /// Types the latest dictation again where the cursor is now. The panel
    /// never takes focus, so this goes to the app the user is in.
    func insertLast() {
        guard let last = history.first else { return }
        target = NSWorkspace.shared.frontmostApplication
        liveText = last.text
        insert(" " + last.text)
    }

    /// The paste-last shortcut: types the latest dictation again. Waits for
    /// the shortcut's own keys to come up first, so they cannot combine with
    /// the typed text (⌘ held while typing "a" would select all).
    func pasteLast() {
        NSLog("figg dictation: paste-last shortcut (%d in history)", history.count)
        guard !capturing else { return }
        guard !history.isEmpty else {
            show(.note("No dictation yet. Hold \(shortcutLabel) to dictate."))
            return
        }
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(1.5)
            while !NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            insertLast()
        }
    }

    var pasteLastLabel: String? { KeyCombo(setting: settings.config.dictation.pasteLastShortcut)?.label }

    func copyLast() {
        guard let last = history.first else { return }
        copy(last)
        show(.note("Copied"))
    }

    func showHistory() {
        if historyWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
            w.title = "Dictation History"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: DictationHistoryView(controller: self).environmentObject(settings))
            w.center()
            historyWindow = w
        }
        reloadHistory()
        historyWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func showSettings() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    var shortcutLabel: String { HoldKey(setting: settings.config.dictation.key).label }

    static func message(for reason: NotInsertedReason) -> String {
        switch reason {
        case .passwordField: return "Not typed into a password field. Saved in Dictation History."
        case .noPermission: return "figg needs Accessibility to type. Saved in Dictation History."
        case .noFocusedApp: return "No text field in front. Saved in Dictation History."
        }
    }

    // MARK: History

    func reloadHistory() {
        history = (try? store.recentDictations(limit: max(settings.config.dictation.historyLimit, 1))) ?? []
    }

    /// Copies one past dictation, only when the user asks.
    func copy(_ dictation: Dictation) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(dictation.text, forType: .string)
    }

    func delete(_ dictation: Dictation) {
        guard let id = dictation.id else { return }
        try? store.deleteDictation(id: id)
        reloadHistory()
    }

    func clearHistory() {
        try? store.clearDictations()
        reloadHistory()
    }

    // MARK: Pill

    private func show(_ phase: Phase) {
        self.phase = phase
        hideTask?.cancel()
        if phase == .idle {
            pill?.hide()
            hovering = false
            return
        }
        if pill == nil { pill = DictationPill(controller: self) }
        pill?.show()
        scheduleHide()
    }

    /// A finished dictation or a note stays up a few seconds so its menu
    /// can be used, then goes. The pointer keeps it up only if it moved after
    /// the panel appeared: the panel often lands right where the mouse was
    /// resting (over the text box being typed into).
    private func scheduleHide() {
        hideTask?.cancel()
        switch phase {
        case .done, .note: break
        default: return
        }
        let restingAt = NSEvent.mouseLocation
        hideTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self else { return }
                let usingIt = self.hovering && NSEvent.mouseLocation != restingAt
                if !usingIt { break }
            }
            self?.show(.idle)
        }
    }
}

/// Whether figg may already use the mic, without prompting.
enum AVCaptureAuthorized {
    static var mic: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
}
