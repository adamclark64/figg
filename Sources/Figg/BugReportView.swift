import AppKit
import FiggExport
import FiggFeedback
import SwiftUI
import UniformTypeIdentifiers

/// The "Report a Bug" window, reachable from the menu bar menu and the Help
/// menu. Thin view over FiggFeedback (hard rule 5): payloads, validation,
/// downscaling and the relay client live in the library.
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
    @State private var filed: (number: Int?, url: URL?)?

    struct Attachment: Identifiable {
        let id = UUID()
        let screenshot: Screenshot
        let thumbnail: NSImage?
    }

    private var endpointURL: URL? {
        let raw = settings.config.feedback.bugReportEndpoint.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, let url = URL(string: raw), url.host != nil else { return nil }
        return url
    }

    private var canSend: Bool {
        !descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let filed {
                successView(filed)
            } else {
                composeView
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(theme.canvas)
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            addProviders(providers)
            return true
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
                }
            }
            Text("Add, paste or drop up to 3 images. Screenshots can show meeting content; attach only what you're happy to share.")
                .font(.caption2)
                .foregroundStyle(theme.inkMuted)
        }
        .onPasteCommand(of: [.image, .fileURL]) { providers in
            addProviders(providers)
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("Email (optional)")
                .font(.caption)
                .foregroundStyle(theme.inkMuted)
            TextField("you@example.com (optional)", text: $email)
                .textFieldStyle(.roundedBorder)
                .disabled(sending)
        }

        if let errorMessage {
            Text(errorMessage)
                .font(.callout)
                .foregroundStyle(theme.record)
            if offerBrowserFallback {
                Button("File on GitHub instead (text only)") { openBrowserFallback() }
            }
        }

        if endpointURL == nil {
            Text("No relay endpoint is set (feedback.bug_report_endpoint in config.yaml), so the report opens as a prefilled GitHub issue in your browser. Screenshots are not included.")
                .font(.caption2)
                .foregroundStyle(theme.inkMuted)
        }

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
        return endpointURL == nil ? "Open GitHub Issue" : "Send Report"
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
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
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
            email: email.trimmingCharacters(in: .whitespaces),
            appVersion: version,
            extra: extra,
            screenshots: attachments.map(\.screenshot))
    }

    private func submit() {
        guard let endpoint = endpointURL else {
            openBrowserFallback()
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

    private func openBrowserFallback() {
        NSWorkspace.shared.open(GitHubIssueURL.url(for: buildPayload()))
        dismiss()
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

    /// Handles both paste and drag-drop. Non-images are skipped (the
    /// downscaler returns nil for anything it cannot decode).
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

    private func addImageData(_ data: Data, name: String) {
        guard attachments.count < BugReportPayload.maxScreenshots,
              let screenshot = ImageDownscaler.screenshot(from: data, name: name) else { return }
        let jpegBase64 = screenshot.base64.replacingOccurrences(of: "data:image/jpeg;base64,", with: "")
        let thumbnail = Data(base64Encoded: jpegBase64).flatMap(NSImage.init(data:))
        attachments.append(Attachment(screenshot: screenshot, thumbnail: thumbnail))
    }
}
