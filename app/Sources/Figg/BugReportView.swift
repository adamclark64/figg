import AppKit
import FiggExport
import FiggFeedback
import SwiftUI
import UniformTypeIdentifiers

/// The "Report a Bug" window, reachable from the menu bar menu and the Help
/// menu. Thin view over FiggFeedback (hard rule 5): payloads, validation,
/// downscaling, the paste rule and the issue link live in the library.
///
/// With no setup the report goes to figg's hosted relay, which files the
/// issue, so no GitHub account is needed. `feedback.bug_report_endpoint`
/// can name another relay, or say "browser" to open the report as a GitHub
/// issue in the browser with screenshots on the clipboard. The browser is
/// also offered when the relay cannot be reached.
///
/// Privacy: nothing is auto-attached beyond app version, build, macOS
/// version, hardware model and the transcriber engine name. Screenshots are
/// user-chosen only; audio, transcripts, notes, meeting titles, calendar
/// data and logs never ride along (hard rule 1).
struct BugReportView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var type: ReportType = .bug
    @State private var descriptionText = ""
    @State private var email = ""
    @State private var attachments: [Attachment] = []
    @State private var sending = false
    @State private var errorMessage: String?
    @State private var offerBrowserFallback = false
    /// Why a pasted or dropped picture was not attached. Kept apart from
    /// `errorMessage` so it never hides a relay failure or its fallback.
    @State private var attachMessage: String?
    @State private var filed: (number: Int?, url: URL?)?
    /// Set once the issue is open in the browser with something left for
    /// the reporter to do there.
    @State private var handedOff: Handoff?

    /// What the reporter still has to carry into the issue by hand.
    struct Handoff {
        /// Screenshots waiting on the clipboard, kept for "Show in Finder".
        var files: [URL]
        /// The whole issue text, when the link could only hold its start.
        var fullBody: String?
    }

    struct Attachment: Identifiable {
        let id = UUID()
        let screenshot: Screenshot
        let thumbnail: NSImage?
    }

    /// The relay to send to, or nil to file in the browser.
    private var endpointURL: URL? {
        BugReportRelay.endpoint(forSetting: settings.config.feedback.bugReportEndpoint)
    }

    private var canSend: Bool {
        !descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let filed {
                successView(filed)
            } else if let handedOff {
                handoffView(handedOff)
            } else {
                composeView
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(theme.canvas)
        .background(PasteCatcher { pasteFromClipboard() })
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            addProviders(providers)
            return true
        }
        // The window is one scene that keeps its state while the app runs,
        // so a finished report is cleared when it closes. A draft is kept.
        .onDisappear {
            if filed != nil || handedOff != nil { reset() }
        }
    }

    // MARK: Compose

    @ViewBuilder private var composeView: some View {
        Text(type.heading)
            .font(Theme.display(20))
            .foregroundStyle(theme.ink)

        Picker("Report type", selection: $type) {
            ForEach(ReportType.allCases, id: \.self) { Text($0.tabLabel) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(sending)

        VStack(alignment: .leading, spacing: 6) {
            Text(type.fieldLabel)
                .font(.caption)
                .foregroundStyle(theme.inkMuted)
            TextEditor(text: $descriptionText)
                .font(.body)
                .frame(height: 110)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line))
                .overlay(alignment: .topLeading) {
                    if descriptionText.isEmpty {
                        Text(type.prompt)
                            .foregroundStyle(theme.inkMuted)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }
                }
                .disabled(sending)
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("Screenshots (\(attachments.count)/\(BugReportPayload.maxScreenshots))")
                .font(.caption)
                .foregroundStyle(theme.inkMuted)
            HStack(spacing: 8) {
                ForEach(attachments) { shot in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let image = shot.thumbnail {
                                Image(nsImage: image).resizable().scaledToFill()
                            } else {
                                Image(systemName: "photo").foregroundStyle(theme.inkMuted)
                            }
                        }
                        .frame(width: 66, height: 66)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.line))
                        Button {
                            attachments.removeAll { $0.id == shot.id }
                            attachMessage = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .disabled(sending)
                        .padding(2)
                        .help("Remove screenshot")
                    }
                }
                if attachments.count < BugReportPayload.maxScreenshots {
                    Button {
                        pickFiles()
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 66, height: 66)
                    }
                    .buttonStyle(.plain)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.line, style: StrokeStyle(dash: [4])))
                    .disabled(sending)
                    .help("Add a screenshot (or paste or drop one)")
                    .contextMenu {
                        Button("Paste Image") { pasteFromClipboard() }
                    }
                }
            }
            Text("Add, paste (\u{2318}V) or drop up to \(BugReportPayload.maxScreenshots) images. Screenshots can show meeting content; attach only what you're happy to share.")
                .font(.caption2)
                .foregroundStyle(theme.inkMuted)
            if let attachMessage {
                Text(attachMessage)
                    .font(.caption)
                    .foregroundStyle(theme.record)
            }
        }
        .onPasteCommand(of: [.image, .fileURL]) { providers in
            addProviders(providers)
        }

        // Only a relay needs an address to reply to. In the browser the
        // issue is filed from the reporter's own GitHub account.
        if endpointURL != nil {
            VStack(alignment: .leading, spacing: 6) {
                Text("Email (optional, shown on the public issue)")
                    .font(.caption)
                    .foregroundStyle(theme.inkMuted)
                TextField("you@example.com (optional)", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .disabled(sending)
            }
        }

        if let errorMessage {
            Text(errorMessage)
                .font(.callout)
                .foregroundStyle(theme.record)
            if offerBrowserFallback {
                Button("Continue on GitHub instead") { openInBrowser() }
            }
        }

        Text(destinationNote)
            .font(.caption2)
            .foregroundStyle(theme.inkMuted)
            .fixedSize(horizontal: false, vertical: true)

        HStack {
            if sending { FigLoadingLabel(text: "Sending your report…") }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(sending)
            Button(sendButtonTitle) { submit() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
        }
    }

    private var sendButtonTitle: String {
        if sending { return "Sending…" }
        return endpointURL == nil ? "Continue on GitHub" : "Send Report"
    }

    /// Says where the report goes before it is sent. Either way it ends up
    /// as a public issue, so the reporter is told.
    private var destinationNote: String {
        guard endpointURL == nil else {
            return "Your report is filed as a public issue on GitHub. You don't need a GitHub account."
        }
        let base = "Your report opens as a public GitHub issue in your browser, where you can read it before you submit. You need a GitHub account."
        return attachments.isEmpty
            ? base
            : base + " Your screenshots are copied to the clipboard, ready to paste into it."
    }

    // MARK: Success

    @ViewBuilder private func successView(_ filed: (number: Int?, url: URL?)) -> some View {
        Text("Report sent")
            .font(Theme.display(20))
            .foregroundStyle(theme.ink)
        Text("Thanks, your report was filed\(filed.number.map { " as issue #\($0)" } ?? "").")
            .foregroundStyle(theme.ink)
        if let url = filed.url {
            Link("View the issue on GitHub", destination: url)
        }
        HStack {
            Spacer()
            Button("Done") { finish() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Handoff

    /// Shown after the issue opened in the browser with something left to
    /// do there (paste the screenshots, or paste a text too long for the
    /// link), so each step is spelled out.
    @ViewBuilder private func handoffView(_ handoff: Handoff) -> some View {
        let files = handoff.files
        Text("Finish on GitHub")
            .font(Theme.display(20))
            .foregroundStyle(theme.ink)
        if let body = handoff.fullBody {
            // The text goes in first: pasting it over the form afterwards
            // would wipe the screenshots.
            Text("Your report is open in your browser, but it was too long for a link, so the form holds only the start. The full report is on your clipboard.")
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(files.isEmpty ? "" : "1. ")Click in the issue text, select all (\u{2318}A) and paste (\u{2318}V).")
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Button("Copy Full Report") { copyText(body) }
            if !files.isEmpty {
                Text("2. Press Copy \(files.count == 1 ? "Screenshot" : "Screenshots"), click under \u{201C}Screenshots\u{201D} in the issue and paste again.")
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(files.count == 1 ? "Copy Screenshot" : "Copy Screenshots") {
                        ScreenshotHandoff.copy(files, to: NSPasteboard.general)
                    }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(files) }
                }
            }
        } else {
            Text("Your report is open in your browser. Click in the issue text and press \u{2318}V to attach your \(files.count == 1 ? "screenshot" : "screenshots"), then submit the issue.")
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !files.isEmpty {
            Text("If a paste adds nothing, drag the files in from Finder.")
                .font(.caption)
                .foregroundStyle(theme.inkMuted)
        }
        HStack {
            if handoff.fullBody == nil {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(files) }
                Button("Copy Again") { ScreenshotHandoff.copy(files, to: NSPasteboard.general) }
            }
            Spacer()
            Button("Done") { finish() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
    }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Closes the window after a report went out, and clears it for the
    /// next one once it is off screen.
    private func finish() {
        dismiss()
        DispatchQueue.main.async { reset() }
    }

    private func reset() {
        type = .bug
        descriptionText = ""
        email = ""
        attachments = []
        sending = false
        errorMessage = nil
        offerBrowserFallback = false
        attachMessage = nil
        filed = nil
        handedOff = nil
    }

    // MARK: Actions

    private func buildPayload() -> BugReportPayload {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        var extra = [
            "macOS": ReportContext.macOSVersion,
            "engine": settings.config.transcription.engine,
        ]
        if !build.isEmpty { extra["build"] = build }
        let hardware = ReportContext.hardwareModel
        if !hardware.isEmpty { extra["hardware"] = hardware }
        return BugReportPayload(
            type: type,
            description: descriptionText.trimmingCharacters(in: .whitespacesAndNewlines),
            // The email field only shows with a relay; never carry one the
            // reporter cannot see.
            email: endpointURL == nil ? "" : email.trimmingCharacters(in: .whitespaces),
            appVersion: version,
            extra: extra,
            screenshots: attachments.map(\.screenshot))
    }

    private func submit() {
        guard let endpoint = endpointURL else {
            openInBrowser()
            return
        }
        sending = true
        errorMessage = nil
        offerBrowserFallback = false
        let payload = buildPayload()
        Task {
            let result = await BugReportClient(endpoint: endpoint).send(payload)
            sending = false
            switch result {
            case let .filed(number, url):
                filed = (number, url)
            case let .failed(message, fallback):
                errorMessage = message
                offerBrowserFallback = fallback
            }
        }
    }

    /// Opens the report as a GitHub issue in the browser. Screenshots
    /// cannot ride the link, so they are saved to a temporary folder and
    /// copied to the clipboard, and the window stays to say so. It also
    /// stays when the text was too long for the link, with the whole report
    /// on the clipboard. If a step fails the window says so and nothing is
    /// lost; the clipboard is only replaced once the browser has opened.
    private func openInBrowser() {
        var payload = buildPayload()
        // The issue is filed from the reporter's own account in the browser.
        payload.email = ""
        errorMessage = nil

        let root = ScreenshotHandoff.root(bundleIdentifier: Bundle.main.bundleIdentifier)
        ScreenshotHandoff.removeOldFolders(in: root)
        var files: [URL] = []
        if !payload.screenshots.isEmpty {
            files = (try? ScreenshotHandoff.writeFiles(payload.screenshots, to: ScreenshotHandoff.newFolder(in: root))) ?? []
            guard files.count == payload.screenshots.count else {
                errorMessage = "Couldn't get your screenshots ready. Try again, or remove them and add them to the issue by hand."
                return
            }
        }

        let link = GitHubIssueURL.link(for: payload)
        guard NSWorkspace.shared.open(link.url) else {
            errorMessage = "Couldn't open your browser. Please try again."
            return
        }
        offerBrowserFallback = false
        if link.wasCut {
            // Text first: the reporter pastes it over the form, then the
            // screenshots go in under it.
            let body = GitHubIssueURL.fullBody(for: payload)
            copyText(body)
            handedOff = Handoff(files: files, fullBody: body)
        } else if files.isEmpty {
            finish()
        } else {
            // If the copy fails the window still says where the files are.
            ScreenshotHandoff.copy(files, to: NSPasteboard.general)
            handedOff = Handoff(files: files, fullBody: nil)
        }
    }

    // MARK: Screenshots

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose up to \(BugReportPayload.maxScreenshots) screenshots"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let data = try? Data(contentsOf: url) {
                addImageData(data, name: url.lastPathComponent)
            }
        }
    }

    /// Takes the paste if the clipboard holds a picture, and says whether
    /// it did. False leaves the paste to the text field. A picture that is
    /// not attached (no room left, or it cannot be read) gets a message, so
    /// a paste never vanishes without a word.
    @discardableResult
    private func pasteFromClipboard() -> Bool {
        guard filed == nil, handedOff == nil, !sending else { return false }
        let room = BugReportPayload.maxScreenshots - attachments.count
        // One more than there is room for, to know when some were left out.
        let images = ClipboardImages.images(on: NSPasteboard.general, limit: room + 1)
        guard !images.isEmpty else {
            // Copied image files that could not be read: say so, or the
            // text field would type their names.
            guard ClipboardImages.holdsImageFiles(NSPasteboard.general) else { return false }
            attachMessage = BugReportErrorMessage.unreadableImage
            return true
        }
        attachMessage = nil
        var unreadable = false
        for image in images.prefix(max(room, 0)) where !addImageData(image.data, name: image.name) {
            unreadable = true
        }
        if images.count > room {
            attachMessage = BugReportErrorMessage.message(for: "too_many_screenshots")
        } else if unreadable {
            attachMessage = BugReportErrorMessage.unreadableImage
        }
        return true
    }

    /// Handles a drop, and a paste made while the focus is outside the text
    /// field. Non-images are skipped (the downscaler returns nil for
    /// anything it cannot decode).
    private func addProviders(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          let file = try? Data(contentsOf: url) else { return }
                    Task { @MainActor in addImageData(file, name: url.lastPathComponent) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in addImageData(data, name: "pasted-image") }
                }
            }
        }
    }

    /// Says whether the image was attached.
    @discardableResult
    private func addImageData(_ data: Data, name: String) -> Bool {
        guard attachments.count < BugReportPayload.maxScreenshots,
              let screenshot = ImageDownscaler.screenshot(from: data, name: name) else { return false }
        let jpegBase64 = screenshot.base64.replacingOccurrences(of: "data:image/jpeg;base64,", with: "")
        let thumbnail = Data(base64Encoded: jpegBase64).flatMap(NSImage.init(data:))
        attachments.append(Attachment(screenshot: screenshot, thumbnail: thumbnail))
        return true
    }
}

/// Catches Command-V for the window it sits in. SwiftUI's paste command only
/// reaches a focused view, and here the focus is in a text field that takes
/// text only, so a copied screenshot went nowhere. This looks at the key
/// first and lets it through unless `onPaste` took it.
///
/// The key is read with Command applied (`characters`), because some
/// keyboard layouts (Russian, "Dvorak - QWERTY Command") only give a Latin
/// "v" while Command is held, and on the second the key that types "v" on
/// its own is Command-Period.
private struct PasteCatcher: NSViewRepresentable {
    /// Returns true when it used the paste.
    var onPaste: () -> Bool

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onPaste = onPaste
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onPaste = onPaste
    }

    final class CatcherView: NSView {
        var onPaste: () -> Bool = { false }
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopWatching()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window,
                      event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                      event.characters?.lowercased() == "v",
                      self.onPaste()
                else { return event }
                return nil
            }
        }

        private func stopWatching() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
