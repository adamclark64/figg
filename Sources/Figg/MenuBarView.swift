import FiggStore
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isRecording, let started = model.recordingStarted {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Label("Recording \(formatTimestamp(ctx.date.timeIntervalSince(started)))", systemImage: "record.circle.fill")
                        .foregroundStyle(.red)
                }
                Button("Stop and write notes") { model.toggleRecording() }
                    .keyboardShortcut(.defaultAction)
                Button("Copy consent message") { model.copyConsentSnippet() }
            } else {
                Button("Start recording") {
                    model.toggleRecording()
                    open()
                }
                .keyboardShortcut(.defaultAction)
            }
            Text("⌃⌥⌘R from any app").font(.caption).foregroundStyle(.secondary)
            Divider()
            Button("Open figg") { open() }
            Button("Report a Bug…") {
                openWindow(id: "bug-report")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 240)
    }

    private func open() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
