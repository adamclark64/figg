import FiggStore
import SwiftUI

/// Past dictations, newest first, to copy from when one went to the wrong
/// place or nowhere. Copying is the only time dictation touches the clipboard.
struct DictationHistoryView: View {
    @ObservedObject var controller: DictationController
    @EnvironmentObject var settings: AppSettings
    @State private var copiedID: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if controller.history.isEmpty {
                ContentUnavailableView(
                    "No dictations yet",
                    systemImage: "mic",
                    description: Text(settings.config.dictation.enabled
                        ? "Hold \(settings.config.dictation.key == "right_option" ? "Right Option" : "fn") in any app and speak."
                        : "Turn on dictation in figg > Settings > Dictation."))
            } else {
                List(controller.history) { d in
                    row(d)
                }
                HStack {
                    Text("Text only; audio is never kept. The last \(settings.config.dictation.historyLimit) are kept.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear All") { controller.clearHistory() }.controlSize(.small)
                }
                .padding(10)
            }
        }
        .onAppear { controller.reloadHistory() }
    }

    private func row(_ d: Dictation) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(d.text).textSelection(.enabled)
                HStack(spacing: 6) {
                    Text(d.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if !d.appName.isEmpty { Text("· \(d.appName)") }
                    if d.outcome == .notInserted {
                        Text("· not inserted").foregroundStyle(.orange)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(copiedID == d.id ? "Copied" : "Copy") {
                controller.copy(d)
                copiedID = d.id
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Copy") { controller.copy(d) }
            Button("Delete", role: .destructive) { controller.delete(d) }
        }
    }
}
