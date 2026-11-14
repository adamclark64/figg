import FiggLLM
import FiggStore
import SwiftUI

struct ChatTurn: Identifiable {
    let id = UUID()
    var question: String
    var answer: String = ""
    var sources: [Meeting] = []
    var error: String?
    var done = false
}

struct ChatView: View {
    @EnvironmentObject var model: AppModel
    @State private var turns: [ChatTurn] = []
    @State private var input = ""
    @State private var busy = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        if turns.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Ask figg").font(Theme.display(30)).foregroundStyle(theme.ink)
                                Text("Ask about any past meeting, e.g. “What did we decide about the launch date?” or “What are my open action items this week?”")
                                    .font(.system(size: 15))
                                    .foregroundStyle(theme.inkMuted)
                            }
                            .padding(.top, 24)
                        }
                        ForEach(turns) { turn in
                            TurnView(turn: turn).id(turn.id)
                        }
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: turns.last?.answer) { _, _ in
                    if let last = turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask figg about your meetings", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...5)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(canSend ? theme.accent : theme.inkMuted.opacity(0.4), in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
                .help("Ask (⌘↩)")
            }
            .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 6)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 19))
            .overlay(RoundedRectangle(cornerRadius: 19).strokeBorder(theme.line))
            .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
            .frame(maxWidth: 720)
            .padding(.horizontal, 40)
            .padding(.bottom, 18)
            .padding(.top, 6)
        }
        .background(theme.canvas)
        .navigationTitle("Ask figg")
    }

    private var canSend: Bool {
        !busy && !input.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func send() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !busy else { return }
        input = ""
        // Earlier turns go back as plain Q/A; only the new question carries meeting context.
        let history = turns.filter { $0.done && $0.error == nil }.flatMap {
            [ChatMessage(role: .user, text: $0.question), ChatMessage(role: .assistant, text: $0.answer)]
        }
        turns.append(ChatTurn(question: question))
        let index = turns.count - 1
        busy = true
        Task {
            defer { busy = false; turns[index].done = true }
            do {
                let (stream, sources) = try model.chat.ask(question, history: history)
                turns[index].sources = sources
                for try await delta in stream { turns[index].answer += delta }
            } catch {
                turns[index].error = error.localizedDescription
            }
        }
    }
}

struct TurnView: View {
    let turn: ChatTurn
    @EnvironmentObject var model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(turn.question).font(Theme.display(20)).foregroundStyle(theme.ink)
            if let error = turn.error {
                Text(error).foregroundStyle(theme.record).textSelection(.enabled)
            } else if turn.answer.isEmpty {
                FigLoadingLabel(text: "Searching your notes…")
            } else {
                Text((try? AttributedString(markdown: turn.answer, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(turn.answer))
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .foregroundStyle(theme.ink)
                    .textSelection(.enabled)
            }
            if turn.done, !turn.sources.isEmpty {
                HStack(spacing: 6) {
                    Text("Searched").foregroundStyle(theme.inkMuted)
                    ForEach(turn.sources.prefix(4)) { m in
                        Button { model.selection = .meeting(m.id) } label: {
                            Chip(icon: "doc.text", text: m.displayTitle)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .font(.caption)
            }
        }
    }
}
