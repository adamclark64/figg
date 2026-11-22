import FiggUpdate
import SwiftUI

/// The update banner's "What's new" sheet: the release notes the version
/// file carried, already picked and cut by `ReleaseNotes.covering`. The
/// notes are untrusted text, so they are only laid out as `Text`; a link in
/// them opens in the browser through SwiftUI's `openURL`, and only on click.
struct ReleaseNotesSheet: View {
    @Environment(\.theme) private var theme
    /// The version the banner offers, so the title names what "Update now" installs.
    let version: String
    let notes: ReleaseNotes
    let update: () -> Void
    let later: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("What's new in figg v\(version)", systemImage: "sparkles")
                .font(Theme.display(18))
                .foregroundStyle(theme.ink)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(notes.sections, id: \.version) { section in
                        SectionView(section: section)
                    }
                    if notes.isCut {
                        Link("See the full changelog", destination: ReleaseNotes.fullChangelog)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("Later", action: later).keyboardShortcut(.cancelAction)
                Button("Update now", action: update).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520, height: 440)
        .background(theme.canvas)
    }

    /// One version's notes: its number, then headings, bullets and paragraphs.
    private struct SectionView: View {
        @Environment(\.theme) private var theme
        let section: ReleaseNotes.Section

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("v\(section.version)")
                    .font(Theme.display(16))
                    .foregroundStyle(theme.ink)
                ForEach(Array(section.blocks.enumerated()), id: \.offset) { _, block in
                    BlockView(block: block)
                }
            }
        }
    }

    private struct BlockView: View {
        @Environment(\.theme) private var theme
        let block: ReleaseNotes.Block

        var body: some View {
            switch block {
            case let .heading(text):
                styled(text).fontWeight(.semibold).padding(.top, 4)
            case let .bullet(text):
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\u{2022}").foregroundStyle(theme.inkMuted)
                    styled(text)
                }
            case let .paragraph(text):
                styled(text)
            }
        }

        private func styled(_ markdown: String) -> Text {
            Text(ReleaseNotes.inline(markdown))
                .font(.system(size: 13.5))
                .foregroundStyle(theme.ink)
        }
    }
}
