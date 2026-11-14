import FiggCalendar
import FiggStore
import FiggWidget
import SwiftUI

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        let theme = Theme.named(settings.config.appearance.theme)
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            VStack(spacing: 0) {
                BannerStack()
                switch model.selection {
                case .ask:
                    ChatView()
                case let .meeting(id):
                    MeetingView(meetingId: id).id(id)
                case nil:
                    EmptyState()
                }
            }
            .background(theme.canvas)
            .toolbarBackground(theme.canvas, for: .windowToolbar)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { RecordButton() }
        }
        .tint(theme.accent)
        .environment(\.theme, theme)
        .environment(\.loaderStyle, LoaderStyle.named(settings.config.appearance.loader))
    }
}

struct RecordButton: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            model.toggleRecording()
        } label: {
            if model.isRecording, let started = model.recordingStarted {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Label("Stop  \(formatTimestamp(ctx.date.timeIntervalSince(started)))", systemImage: "stop.circle.fill")
                }
                .foregroundStyle(theme.record)
            } else {
                Label("Record", systemImage: "record.circle")
            }
        }
        .help("Start or stop recording (⌃⌥⌘R from any app)")
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        List(selection: $model.selection) {
            Label("Ask figg", systemImage: "bubble.left.and.text.bubble.right")
                .tag(SidebarItem.ask)
            ForEach(Self.byDay(model.meetings), id: \.day) { group in
                Section {
                    ForEach(group.meetings) { meeting in
                        MeetingRow(meeting: meeting, isRecording: model.recordingId == meeting.id)
                            .tag(SidebarItem.meeting(meeting.id))
                            .contextMenu {
                                Button("Delete", role: .destructive) { model.delete(meeting.id) }
                                    .disabled(model.recordingId == meeting.id)
                            }
                    }
                } header: {
                    Text(Self.dayLabel(group.day))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.inkMuted)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.sidebar)
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search notes and transcripts")
        .safeAreaInset(edge: .bottom) { WhisperStatus().padding(8) }
    }

    /// Meetings grouped by calendar day, newest first (the list arrives newest first).
    static func byDay(_ meetings: [Meeting]) -> [(day: Date, meetings: [Meeting])] {
        let cal = Calendar.current
        var groups: [(day: Date, meetings: [Meeting])] = []
        for m in meetings {
            let day = cal.startOfDay(for: m.createdAt)
            if groups.last?.day == day { groups[groups.count - 1].meetings.append(m) }
            else { groups.append((day, [m])) }
        }
        return groups
    }

    static func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let sameYear = cal.isDate(day, equalTo: .now, toGranularity: .year)
        return day.formatted(sameYear ? .dateTime.weekday(.abbreviated).month(.abbreviated).day()
                                      : .dateTime.month(.abbreviated).day().year())
    }
}

struct MeetingRow: View {
    let meeting: Meeting
    let isRecording: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if isRecording {
                    Circle().fill(theme.record).frame(width: 7, height: 7)
                }
                Text(meeting.displayTitle).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(meeting.createdAt, format: .dateTime.hour().minute())
                switch meeting.status {
                case .transcribing: Text("· transcribing")
                case .enhancing: Text("· enhancing")
                case .needsEnhance: Text("· not enhanced")
                case .failed: Text("· failed")
                default: EmptyView()
                }
            }
            .font(.caption)
            .foregroundStyle(theme.inkMuted)
        }
        .padding(.vertical, 3)
    }
}

struct WhisperStatus: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.whisperState {
        case .notDownloaded:
            VStack(alignment: .leading, spacing: 4) {
                Text("figg needs a speech model to transcribe on this Mac (one-time download: about 0.5 GB for Parakeet, 1.5 GB for Whisper).")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Download speech model") { Task { await model.loadWhisper() } }.controlSize(.small)
            }
        case .loading:
            FigLoadingLabel(text: "Loading speech model…", size: 28)
                .font(.caption)
        case let .failed(message):
            VStack(alignment: .leading) {
                Text("Speech model failed: \(message)").font(.caption).foregroundStyle(.red).lineLimit(3)
                Button("Retry") { Task { await model.loadWhisper() } }.controlSize(.small)
            }
        default:
            EmptyView()
        }
    }
}

struct BannerStack: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        UpdateProgressBanner(updates: model.updates)
        VStack(spacing: 4) {
            ForEach(model.banners) { banner in
                HStack(alignment: .top) {
                    Image(systemName: icon(banner.kind)).foregroundStyle(color(banner.kind))
                    Text(banner.text).foregroundStyle(theme.ink).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    if let action = banner.action {
                        Button(label(action)) { model.perform(action); model.dismiss(banner) }
                    }
                    Button { model.dismiss(banner) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                .padding(10)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color(banner.kind).opacity(0.35)))
            }
        }
        .padding(.horizontal, model.banners.isEmpty ? 0 : 12)
        .padding(.top, model.banners.isEmpty ? 0 : 8)
    }

    func icon(_ k: Banner.Kind) -> String {
        switch k { case .info: "info.circle"; case .warning: "exclamationmark.triangle"; case .error: "xmark.octagon" }
    }

    func color(_ k: Banner.Kind) -> Color {
        switch k { case .info: theme.accent; case .warning: .orange; case .error: theme.record }
    }

    func label(_ a: Banner.Action) -> String {
        switch a { case .ssoLogin: "Sign in to AWS"; case .retryEnhance: "Retry"; case .openPrivacySettings: "Open Settings"; case .installUpdate: "Update now"; case .allowAccessibility: "Allow" }
    }
}

/// Shows the update downloading and installing. The "Update now" banner is
/// dismissed when clicked, so without this nothing showed until figg
/// relaunched or failed. Observes UpdateManager directly, since AppModel
/// does not republish its nested object's changes.
private struct UpdateProgressBanner: View {
    @ObservedObject var updates: UpdateManager
    @Environment(\.theme) private var theme

    var body: some View {
        switch updates.phase {
        case .downloading:
            row(FigLoadingLabel(text: "Downloading the update…", progress: updates.downloadProgress, size: 44))
        case .installing:
            row(FigLoadingLabel(text: "Installing the update. figg restarts when it's done.", size: 44))
        default:
            EmptyView()
        }
    }

    private func row(_ label: FigLoadingLabel) -> some View {
        label
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.accent.opacity(0.35)))
            .padding(.horizontal, 12)
            .padding(.top, 8)
    }
}

struct EmptyState: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 14) {
            if let event = model.upcomingEvent { UpcomingMeetingCard(event: event) }
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Press Record when your meeting starts.")
                .font(Theme.display(24))
                .foregroundStyle(theme.ink)
            Text("Type rough notes while it records. When you stop, figg writes them up from the transcript.")
                .font(.system(size: 14))
                .foregroundStyle(theme.inkMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 10) {
                Button("Record") { model.toggleRecording() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                Button("Ask figg") { model.selection = .ask }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.canvas)
    }
}

/// The calendar meeting happening now or next, with a one-click prep brief
/// built from past figg notes. Only shown when the calendar is enabled.
struct UpcomingMeetingCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.theme) private var theme
    let event: FiggCalendar.CalendarEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "calendar.badge.clock").foregroundStyle(theme.accent)
                Text(event.start <= Date() ? "Now:" : "Next:").foregroundStyle(theme.inkMuted)
                Text(event.title.isEmpty ? "Untitled event" : event.title)
                    .fontWeight(.semibold).foregroundStyle(theme.ink).lineLimit(1)
                Text(event.start, format: .dateTime.hour().minute()).foregroundStyle(theme.inkMuted)
            }
            if !event.attendees.isEmpty {
                Text(event.attendees.joined(separator: ", "))
                    .font(.caption).foregroundStyle(theme.inkMuted).lineLimit(1)
            }
            Button("Pre-meeting brief") { Task { await model.runBrief() } }
                .controlSize(.small)
                .help("What you last discussed with these people, from your past notes")
        }
        .padding(12)
        .frame(maxWidth: 420, alignment: .leading)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.line))
        .padding(.bottom, 10)
        .sheet(isPresented: Binding(
            get: { model.briefResult != nil },
            set: { if !$0 { model.briefResult = nil } }
        )) {
            if let brief = model.briefResult {
                GeneratedDocSheet(
                    title: "Brief: \(brief.eventTitle)", icon: "calendar.badge.clock",
                    text: brief.text, running: brief.running, error: brief.error
                ) { model.briefResult = nil }
            }
        }
    }
}
