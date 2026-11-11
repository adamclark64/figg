import FiggExport
import FiggNotes
import FiggStore
import SwiftUI

struct MeetingView: View {
    let meetingId: String
    @EnvironmentObject var model: AppModel
    @Environment(\.theme) private var theme

    @State private var meeting: Meeting?
    @State private var title = ""
    @State private var notes = ""
    @State private var lines: [TranscriptLine] = []
    @State private var tab: Tab = .notes
    @State private var showTranscript = true
    @State private var editingEnhanced = false
    @State private var enhancedDraft = ""
    @State private var templateId = ""  // "" = the configured default

    enum Tab: Hashable { case notes, enhanced }

    var isRecording: Bool { model.recordingId == meetingId }
    var streaming: String? { model.enhancingText[meetingId] }

    var body: some View {
        HSplitView {
            // A centred reading column, like a page in a notebook.
            VStack(alignment: .leading, spacing: 14) {
                header
                if isRecording { RecordingStrip(model: model, meetingId: meetingId) }
                NotesTabs(tab: $tab, hasEnhanced: (streaming ?? meeting?.enhancedNotes) != nil)

                switch tab {
                case .notes:
                    TextEditor(text: $notes)
                        .font(.system(size: 15))
                        .lineSpacing(5)
                        .foregroundStyle(theme.ink)
                        .scrollContentBackground(.hidden)
                        .overlay(alignment: .topLeading) {
                            if notes.isEmpty {
                                Text("Type rough notes here. figg fills in the rest.")
                                    .font(.system(size: 15))
                                    .foregroundStyle(theme.inkMuted.opacity(0.7))
                                    .padding(.leading, 5).allowsHitTesting(false)
                            }
                        }
                        .onChange(of: notes) { _, new in model.saveNotes(meetingId, new) }
                case .enhanced:
                    enhancedPane
                }
            }
            .frame(maxWidth: 720, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 40)
            .padding(.top, 28)
            .padding(.bottom, 16)
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.canvas)

            if showTranscript {
                TranscriptPane(lines: lines, live: isRecording, attendees: meeting?.attendees ?? []) { from, to in
                    model.renameSpeaker(meetingId, from: from, to: to)
                }
                .frame(minWidth: 240, idealWidth: 320, maxWidth: 480)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    tab = .enhanced
                    Task { await model.enhance(meetingId) }
                } label: {
                    Label(meeting?.enhancedNotes == nil ? "Enhance" : "Regenerate", systemImage: "sparkles")
                }
                .disabled(isRecording || meeting?.status == .enhancing || meeting?.status == .transcribing)

                Menu {
                    ForEach(QuickAction.allCases) { action in
                        Button {
                            Task { await model.runQuickAction(meetingId, action) }
                        } label: {
                            Label(action.name, systemImage: action.icon)
                        }
                    }
                } label: {
                    Label("Quick actions", systemImage: "bolt")
                }
                .disabled(isRecording || meeting?.status == .enhancing || meeting?.status == .transcribing)
                .help("One-click documents from this meeting: shown to copy, not saved")

                if let meeting { ExportMenu(meeting: meeting) }

                Toggle(isOn: $showTranscript) { Label("Transcript", systemImage: "text.bubble") }
            }
        }
        .onAppear(perform: load)
        .onChange(of: model.transcriptVersion) { _, _ in lines = model.transcript(meetingId) }
        .onChange(of: model.meetings) { _, _ in refreshMeeting() }
        .onChange(of: streaming) { _, new in if new != nil { tab = .enhanced } }
        .sheet(isPresented: Binding(
            get: { model.quickActionResults[meetingId] != nil },
            set: { if !$0 { model.quickActionResults[meetingId] = nil } }
        )) {
            if let result = model.quickActionResults[meetingId] {
                GeneratedDocSheet(
                    title: result.action.name, icon: result.action.icon,
                    text: result.text, running: result.running, error: result.error
                ) { model.quickActionResults[meetingId] = nil }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Untitled meeting", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.display(30))
                .foregroundStyle(theme.ink)
                .onSubmit { model.rename(meetingId, to: title) }
            if let meeting {
                HStack(spacing: 8) {
                    Chip(icon: "calendar", text: Self.when(meeting.createdAt))
                    if !speakers.isEmpty { Chip(icon: "person.2", text: speakers.joined(separator: ", ")) }
                    if let status = statusText(meeting) {
                        if status.running { LoadingChip(text: status.text) } else { Chip(icon: status.icon, text: status.text) }
                    }
                    templateMenu
                }
            }
            if let error = meeting?.errorMessage, meeting?.status == .needsEnhance {
                Text(error).font(.callout).foregroundStyle(theme.inkMuted).textSelection(.enabled)
            }
        }
    }

    /// The meeting-type template, as a chip-styled menu next to the metadata.
    /// Changing it only affects the next Enhance (or Regenerate).
    private var templateMenu: some View {
        Menu {
            Picker("Template", selection: $templateId) {
                Text("Default (\(NoteTemplate.named(model.settings.config.notes.template).name))").tag("")
                Divider()
                ForEach(NoteTemplate.all) { t in Text(t.name).tag(t.id) }
            }
            .pickerStyle(.inline)
        } label: {
            Chip(icon: "doc.text", text: templateId.isEmpty
                ? NoteTemplate.named(model.settings.config.notes.template).name
                : NoteTemplate.named(templateId).name)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Meeting type: shapes the sections Enhance writes")
        .onChange(of: templateId) { _, new in
            model.setTemplate(meetingId, new.isEmpty ? nil : new)
        }
    }

    /// Speakers in order of first appearance ("Me, Them 1, Guest 1").
    private var speakers: [String] {
        var seen = Set<String>()
        return lines.map(\.displaySpeaker).filter { seen.insert($0).inserted }
    }

    /// "Today 11:23", "Yesterday 09:00", or "Mon, Nov 3 14:00".
    static func when(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today \(time)" }
        if cal.isDateInYesterday(date) { return "Yesterday \(time)" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " " + time
    }

    /// `running` statuses show the loader instead of an icon.
    private func statusText(_ m: Meeting) -> (icon: String, text: String, running: Bool)? {
        switch m.status {
        case .recording: return isRecording ? nil : ("record.circle", "Recording", false)
        case .transcribing: return ("", "Finishing transcript…", true)
        case .enhancing: return ("", "Writing notes…", true)
        case .needsEnhance: return ("exclamationmark.circle", "Not enhanced", false)
        default: return nil
        }
    }

    @ViewBuilder private var enhancedPane: some View {
        let text = streaming ?? meeting?.enhancedNotes
        if editingEnhanced {
            VStack(alignment: .trailing) {
                TextEditor(text: $enhancedDraft).font(.system(size: 13, design: .monospaced)).scrollContentBackground(.hidden)
                HStack {
                    Button("Cancel") { editingEnhanced = false }
                    Button("Save") {
                        model.saveEnhanced(meetingId, enhancedDraft)
                        editingEnhanced = false
                        refreshMeeting()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        } else if let text, !text.isEmpty {
            ScrollView {
                // No toggling while Enhance streams: that text is not saved yet.
                EnhancedNotesView(
                    lines: Provenance.mark(enhanced: text, userNotes: notes),
                    onToggle: streaming != nil ? nil : { line in
                        model.toggleCheckbox(meetingId, line: line)
                        refreshMeeting()
                    }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay(alignment: .topTrailing) {
                if streaming == nil {
                    Button("Edit") {
                        enhancedDraft = text
                        editingEnhanced = true
                    }
                    .controlSize(.small)
                } else {
                    FigLoader(size: 34)
                        .help("Writing notes…")
                        .accessibilityLabel("Writing notes")
                }
            }
            HStack(spacing: 14) {
                Label("Your notes", systemImage: "circle.fill").foregroundStyle(theme.ink)
                Label("Added by figg", systemImage: "circle.fill").foregroundStyle(theme.inkMuted)
            }
            .font(.caption)
            .labelStyle(.titleAndIcon)
        } else if streaming != nil || meeting?.status == .enhancing {
            // Enhance has started but no text has arrived yet (the title is
            // suggested first). Without this the empty state below offers
            // "Enhance now", which would start a second run.
            FigLoadingPlaceholder(text: "Writing notes…")
        } else if meeting?.status == .transcribing {
            // Notes are written as soon as the final pass ends. Offering
            // "Enhance now" here would write them from a transcript that is
            // about to be replaced.
            FigLoadingPlaceholder(text: "Finishing transcript…")
        } else {
            VStack(spacing: 10) {
                Text("No enhanced notes yet.").font(Theme.display(17, .regular)).foregroundStyle(theme.inkMuted)
                if !isRecording {
                    Button("Enhance now") { Task { await model.enhance(meetingId) } }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load() {
        refreshMeeting()
        title = meeting?.title ?? ""
        notes = meeting?.userNotes ?? ""
        templateId = meeting?.template ?? ""
        lines = model.transcript(meetingId)
    }

    private func refreshMeeting() {
        meeting = model.meeting(meetingId)
        if let t = meeting?.title, !t.isEmpty, title.isEmpty { title = t }
    }
}

/// A generated document (quick action or pre-meeting brief), streaming in;
/// copy is the only output, nothing is saved.
struct GeneratedDocSheet: View {
    @Environment(\.theme) private var theme
    let title: String
    let icon: String
    let text: String
    let running: Bool
    let error: String?
    let dismiss: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: icon)
                    .font(Theme.display(18))
                    .foregroundStyle(theme.ink)
                if running { FigLoader(size: 34).accessibilityLabel("Writing") }
                Spacer()
            }
            if let error {
                Text(error).foregroundStyle(theme.record).textSelection(.enabled)
                Spacer()
            } else if text.isEmpty && running {
                FigLoadingPlaceholder(text: "Writing…")
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 8))
            } else {
                ScrollView {
                    Text(text.isEmpty ? "Writing…" : text)
                        .font(.system(size: 13.5))
                        .lineSpacing(3)
                        .foregroundStyle(text.isEmpty ? theme.inkMuted : theme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                }
                .disabled(running || text.isEmpty)
                Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520, height: 440)
        .background(theme.canvas)
    }
}

/// "My notes" / "Enhanced" as a pill toggle instead of a stock segmented control.
struct NotesTabs: View {
    @Environment(\.theme) private var theme
    @Binding var tab: MeetingView.Tab
    let hasEnhanced: Bool

    var body: some View {
        HStack(spacing: 2) {
            item(.notes, "My notes", "text.alignleft")
            item(.enhanced, "Enhanced", "sparkles")
        }
        .padding(3)
        .background(theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(theme.line))
    }

    private func item(_ t: MeetingView.Tab, _ title: String, _ icon: String) -> some View {
        Button { tab = t } label: {
            Label(title, systemImage: icon)
                .font(.callout.weight(tab == t ? .semibold : .regular))
                .foregroundStyle(tab == t ? theme.accent : theme.inkMuted)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(tab == t ? theme.accentSoft : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(t == .enhanced && !hasEnhanced && tab != .enhanced ? 0.6 : 1)
    }
}

struct RecordingStrip: View {
    @Environment(\.theme) private var theme
    @ObservedObject var model: AppModel
    let meetingId: String
    @State private var copied = false
    @State private var roomSpeakers = 0  // 0 = auto

    var body: some View {
        HStack {
            Image(systemName: "record.circle.fill").foregroundStyle(theme.record)
            Text("Recording. Audio stays on this Mac.").foregroundStyle(theme.ink)
            if let meter = model.levelMeter {
                LiveWaveform(meter: meter).padding(.leading, 8)
            }
            Spacer()
            Picker("People in the room", selection: $roomSpeakers) {
                Text("Auto").tag(0)
                ForEach(1...6, id: \.self) { Text("\($0)").tag($0) }
            }
            .fixedSize()
            .help("How many people share this Mac's mic (not counting the call). Helps figg tell voices apart when you stop.")
            .onChange(of: roomSpeakers) { _, n in model.setRoomSpeakers(meetingId, n == 0 ? nil : n) }
            Button(copied ? "Copied" : "Copy consent message") {
                model.copyConsentSnippet()
                copied = true
            }
            .help(AppModel.consentSnippet)
            .controlSize(.small)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct EnhancedNotesView: View {
    @Environment(\.theme) private var theme
    let lines: [NoteLine]
    /// Called with a line's `NoteLine.id` when its checkbox is clicked.
    /// nil draws the boxes but leaves them inert.
    var onToggle: ((Int) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lines) { line in
                row(line).foregroundStyle(line.isUsers ? theme.ink : theme.inkMuted)
            }
        }
        .font(.system(size: 15))
        .lineSpacing(4)
        .textSelection(.enabled)
    }

    @ViewBuilder private func row(_ line: NoteLine) -> some View {
        let indent = CGFloat(line.text.prefix(while: { $0 == " " }).count / 2) * 16
        let t = line.text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty {
            Spacer().frame(height: 4)
        } else if let h = t.firstMatch(of: #/^(#{1,6})\s+(.+)$/#) {
            Text(inline(String(h.2)))
                .font(h.1.count <= 2 ? Theme.display(20) : Theme.display(16))
                .foregroundStyle(theme.ink)
                .padding(.top, h.1.count <= 2 ? 12 : 6)
        } else if let box = Checkboxes.match(t) {
            HStack(alignment: .firstTextBaseline) {
                Button {
                    onToggle?(line.id)
                } label: {
                    Image(systemName: box.done ? "checkmark.square" : "square")
                        .foregroundStyle(theme.accent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .allowsHitTesting(onToggle != nil)  // not .disabled: that dims the box while notes stream
                .help(box.done ? "Mark as not done" : "Mark as done")
                .accessibilityLabel(box.label)
                .accessibilityValue(box.done ? "Done" : "Not done")
                .accessibilityAddTraits(.isToggle)
                Text(inline(box.label))
                    .strikethrough(box.done)
                    .opacity(box.done ? 0.6 : 1)
            }
            .padding(.leading, indent)
        } else if let b = t.firstMatch(of: #/^[-*+]\s+(.+)$/#) {
            HStack(alignment: .firstTextBaseline) {
                Text("•").foregroundStyle(theme.accent)
                Text(inline(String(b.1)))
            }
            .padding(.leading, indent)
        } else {
            Text(inline(t)).padding(.leading, indent)
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

struct TranscriptPane: View {
    @Environment(\.theme) private var theme
    let lines: [TranscriptLine]
    let live: Bool
    var attendees: [String] = []
    var onRename: (String, String) -> Void = { _, _ in }
    @State private var renaming: String?  // the label being renamed
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transcript").font(Theme.display(15)).foregroundStyle(theme.ink)
                if live {
                    Text("LIVE").font(.caption2.weight(.semibold)).tracking(0.8)
                        .foregroundStyle(theme.record)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(theme.record.opacity(0.12), in: Capsule())
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Rectangle().fill(theme.line).frame(height: 1)
            if lines.isEmpty {
                Text(live ? "Listening… lines appear about every 10 seconds." : "No transcript.")
                    .foregroundStyle(theme.inkMuted).padding(16)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    List(lines) { line in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(line.displaySpeaker).font(.caption.weight(.semibold))
                                    .foregroundStyle(line.speaker == .me ? theme.accent : theme.ink)
                                Text(formatTimestamp(line.start)).font(.caption.monospacedDigit())
                                    .foregroundStyle(theme.inkMuted)
                            }
                            Text(line.text).font(.system(size: 13.5)).foregroundStyle(theme.ink)
                                .lineSpacing(2).textSelection(.enabled)
                        }
                        .padding(.vertical, 3)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .id(line.id)
                        .contextMenu { renameMenu(for: line.displaySpeaker) }
                    }
                    .scrollContentBackground(.hidden)
                    .onChange(of: lines.count) { _, _ in
                        if live, let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .background(theme.sidebar)
        .alert("Rename \(renaming ?? "speaker")", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let from = renaming { onRename(from, renameText) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Applies to every \"\(renaming ?? "")\" line in this meeting.")
        }
    }

    /// Rename a speaker to a calendar attendee in one click, or to any name.
    @ViewBuilder private func renameMenu(for speaker: String) -> some View {
        let taken = Set(lines.map(\.displaySpeaker))
        ForEach(attendees.filter { !taken.contains($0) }, id: \.self) { name in
            Button("Rename \(speaker) to \(name)") { onRename(speaker, name) }
        }
        Button("Rename \(speaker)…") {
            renameText = speaker
            renaming = speaker
        }
    }
}
