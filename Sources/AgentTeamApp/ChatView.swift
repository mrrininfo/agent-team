import AgentTeamCore
import AppKit
import SwiftUI

struct ChatView: View {
    @Bindable var o: Orchestrator
    let chatId: String
    @State private var draft = ""
    @State private var transferFrom = ""

    var body: some View {
        if let c = o.chat(chatId), let i = o.team.agents.firstIndex(where: { $0.id == c.agentId }) {
            let agent = o.team.agents[i]
            VStack(spacing: 0) {
                header(c, agent, profile: $o.team.agents[i].profile)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(c.messages) { MessageRow(m: $0) }
                            if !c.activity.isEmpty {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text(c.activity).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding()
                    }
                    .onChange(of: c.messages.count) { proxy.scrollTo("end") }
                    .onAppear { proxy.scrollTo("end") }
                }
                Divider()
                transferBar(c, agent)
                composer(c)
            }
        } else {
            ContentUnavailableView("Chat không tồn tại", systemImage: "bubble.left.and.exclamationmark.bubble.right")
        }
    }

    func header(_ c: Chat, _ agent: Agent, profile: Binding<Profile>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Tiêu đề", text: Binding(get: { c.title }, set: { o.rename(chatId, $0) }))
                    .textFieldStyle(.plain).font(.title3.bold())
                Spacer()
                Label(c.status.title, systemImage: "circle.fill").foregroundStyle(c.status.color).font(.caption)
                if c.status == .running || c.status == .queued {
                    Button("Dừng") { o.stop(chatId) }
                }
            }
            HStack(spacing: 10) {
                Text("\(o.team.role(agent.roleId)?.name ?? agent.roleId) · \(agent.id) · chat \(c.id) · \(c.tokens.formatted()) token")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                if let r = c.runningProfile ?? o.team.effectiveProfile(for: agent), r != agent.profile {
                    Text("→ đang dùng \(r.label)").font(.caption).foregroundStyle(.orange)
                }
            }
            ProfileEditor(profile: profile)
            if let to = c.replyTo {
                Text("Kết quả sẽ báo về chat \(to) · \(o.chat(to)?.title ?? "")").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    func transferBar(_ c: Chat, _ agent: Agent) -> some View {
        // Chats of the same role that can be taken over (limited/failed first).
        let sources = o.chats.filter { s in
            s.id != c.id && s.status != .running && o.team.agent(s.agentId)?.roleId == agent.roleId
                && (s.status != .done || !s.pending.isEmpty || !s.inFlight.isEmpty || s.replyTo != nil)
        }.sorted { ($0.status == .limited || $0.status == .failed) && !($1.status == .limited || $1.status == .failed) }
        if !sources.isEmpty {
            HStack {
                Text("Tiếp tục việc từ").font(.callout).foregroundStyle(.secondary)
                Picker("", selection: $transferFrom) {
                    Text("—").tag("")
                    ForEach(sources) { s in Text("\(s.title) · \(s.status.title)").tag(s.id) }
                }
                .labelsHidden().frame(maxWidth: 280)
                Button("Chuyển việc") {
                    o.transfer(from: transferFrom, to: chatId)
                    transferFrom = ""
                }
                .disabled(transferFrom.isEmpty)
                .help("Gói nhiệm vụ, tiến độ, ghi chú và git status của chat cũ rồi giao cho chat này; kết quả vẫn báo về người giao ban đầu.")
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 8)
        }
    }

    func sendDraft() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        o.send(t, to: chatId)
        draft = ""
    }

    func composer(_ c: Chat) -> some View {
        HStack(alignment: .bottom) {
            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 44, maxHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                // Enter sends, Shift+Enter inserts a newline. While an input method (e.g. Vietnamese Telex)
                // is still composing a word, Enter belongs to it, so the word is committed rather than lost.
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    if (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true { return .ignored }
                    sendDraft()
                    return .handled
                }
            Button { sendDraft() } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
            .buttonStyle(.borderless)
            .help("Gửi (↩) · xuống hàng: ⇧↩")
        }
        .padding(12)
    }
}

struct MessageRow: View {
    let m: Message

    var label: String {
        switch m.kind {
        case .user: "Bạn"
        case .assistant: "Agent"
        case .task: "Giao việc"
        case .callback: "Phản hồi"
        case .handoff: "Bàn giao"
        case .system: "Hệ thống"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption.bold()).foregroundStyle(m.kind == .system ? Color.orange : .secondary)
                Text(m.date, style: .time).font(.caption2).foregroundStyle(.tertiary)
            }
            if [.task, .callback, .handoff].contains(m.kind) && m.text.count > 600 {
                DisclosureGroup(String(m.text.prefix(160)) + "…") { body(m.text) }
            } else {
                body(m.text)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(background))
    }

    func body(_ text: String) -> some View {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
            .textSelection(.enabled)
            .font(m.kind == .assistant || m.kind == .user ? .body : .callout)
    }

    var background: Color {
        switch m.kind {
        case .user: .accentColor.opacity(0.15)
        case .assistant: Color.secondary.opacity(0.08)
        case .system: .orange.opacity(0.08)
        default: .purple.opacity(0.08)
        }
    }
}

/// Provider + model + effort picker, used for agents, fallbacks and bulk replace.
struct ProfileEditor: View {
    @Binding var profile: Profile

    var body: some View {
        HStack(spacing: 4) {
            Picker("", selection: $profile.provider) {
                ForEach(Provider.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().frame(width: 125)
            .onChange(of: profile.provider) { _, p in
                if !p.suggestedModels.contains(profile.model) { profile.model = p.suggestedModels.first ?? "" }
                if !p.efforts.contains(profile.effort) { profile.effort = "" }
            }
            TextField("", text: $profile.model, prompt: Text("model")).labelsHidden().frame(width: 160)
            Menu {
                ForEach(profile.provider.suggestedModels, id: \.self) { m in Button(m) { profile.model = m } }
            } label: { Image(systemName: "chevron.down") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
            Picker("", selection: $profile.effort) {
                ForEach(profile.provider.efforts, id: \.self) { Text($0.isEmpty ? "effort mặc định" : $0).tag($0) }
            }
            .labelsHidden().frame(width: 125)
            .disabled(profile.provider.efforts.count < 2)
        }
    }
}
