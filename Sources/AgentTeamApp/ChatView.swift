import AgentTeamCore
import AppKit
import SwiftUI

struct ChatView: View {
    @Bindable var o: Orchestrator
    let chatId: String
    @Environment(PreviewState.self) private var preview
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var transferFrom = ""
    @State private var attachments: [Attachment] = []
    @State private var attachError = ""
    @State private var dropTargeted = false
    @State private var pasteMonitor: Any?

    var body: some View {
        if let c = o.chat(chatId), let i = o.team.agents.firstIndex(where: { $0.id == c.agentId }) {
            let agent = o.team.agents[i]
            VStack(spacing: 0) {
                header(c, agent, profile: $o.team.agents[i].profile)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(c.messages) { MessageRow(m: $0, root: o.paths.workspace) }
                            if !c.activity.isEmpty {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text(c.activity).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                // Silence watchdog, shown before it acts so a long command is visible as such.
                                TimelineView(.periodic(from: .now, by: 15)) { ctx in
                                    if let t = o.lastSignal[chatId], ctx.date.timeIntervalSince(t) >= 120 {
                                        let mins = Int(ctx.date.timeIntervalSince(t) / 60)
                                        Label("Không có tín hiệu \(mins) phút; tự dừng và chạy lại khi tới \(Int(o.stallLimit / 60)) phút.",
                                              systemImage: "hourglass")
                                            .font(.caption).foregroundStyle(.orange)
                                    }
                                }
                            }
                            if let at = o.retryAt[chatId] {
                                HStack {
                                    Label("Chờ mạng: tự thử lại lúc \(at.formatted(date: .omitted, time: .shortened)) hoặc ngay khi có mạng.",
                                          systemImage: "wifi.exclamationmark")
                                        .font(.caption).foregroundStyle(.orange)
                                    Button("Thử ngay") { o.retryNow(chatId) }.controlSize(.small)
                                }
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding()
                    }
                    .onChange(of: c.messages.count) { proxy.scrollTo("end") }
                    .onAppear { proxy.scrollTo("end") }
                }
                // Links in messages (reports, attachments, file paths) open in the preview pane.
                .environment(\.openURL, OpenURLAction { url in
                    guard let file = resolveLocal(url, root: o.paths.workspace) else { return .systemAction }
                    preview.open(file)
                    return .handled
                })
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
                let curProfile = c.runningProfile ?? o.team.effectiveProfile(for: agent)
                if let rep = c.verifiedModel(for: curProfile) {
                    Text("model: \(rep) (đã xác minh)").font(.caption).foregroundStyle(.blue)
                } else {
                    let cfg = curProfile?.model ?? agent.profile.model
                    Text("model: \(cfg) (cấu hình)").font(.caption).foregroundStyle(.secondary)
                }
                if let r = c.runningProfile ?? o.team.effectiveProfile(for: agent), r != agent.profile {
                    Text("→ đang dùng \(r.label)").font(.caption).foregroundStyle(.orange)
                }
            }
            ProfileEditor(profile: profile)
            if let t = c.lastTiming {
                Text("Lượt cuối: tín hiệu đầu sau \(t.firstSignal.map(Self.seconds) ?? "—") · tổng \(Self.seconds(t.total)) · \(t.provider)"
                     + (c.context.map { " · context \($0 / 1000)k" + (c.contextWindow.map { "/\($0 / 1000)k" } ?? "") } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Tín hiệu đầu = thời gian CLI khởi động, nạp phiên/plugin/MCP tới lúc in ra dòng đầu tiên. Mọi lượt được ghi ở .agentteam/logs/turns.csv")
            }
            if let r = c.relay {
                Text("\(r.mode == .debate ? "Đang phản biện tự động" : "Đang nghiệm thu tự động") với \(o.team.agent(r.reviewerAgent).flatMap { o.team.role($0.roleId) }?.name ?? r.reviewerAgent) · vòng \(r.round)/\(r.maxRounds)")
                    .font(.caption).foregroundStyle(.blue)
            }
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

    static func seconds(_ t: TimeInterval) -> String {
        t < 60 ? String(format: "%.0f giây", t) : "\(Int(t) / 60) phút \(Int(t) % 60) giây"
    }

    func sendDraft() {
        var t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || !attachments.isEmpty else { return }
        if !attachments.isEmpty {
            do {
                let saved = try Attachment.store(attachments, in: o.paths.root.appendingPathComponent("attachments/\(chatId)"))
                let rel = saved.map { $0.path.replacingOccurrences(of: o.paths.workspace.path + "/", with: "") }
                t += (t.isEmpty ? "" : "\n\n") + Attachment.marker + "\n" + rel.map { "- \($0)" }.joined(separator: "\n")
            } catch {
                attachError = "Không lưu được file đính kèm: \(error.localizedDescription)"
                return
            }
        }
        o.send(t, to: chatId)
        draft = ""
        attachments = []
        attachError = ""
    }

    func add(_ items: [Attachment]) {
        let (ok, err) = Attachment.accept(items, existing: attachments)
        attachments += ok
        attachError = err ?? ""
    }

    func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Chọn file/ảnh đính kèm (tối đa \(Attachment.maxCount) file, mỗi file ≤ \(Attachment.maxBytes / 1_000_000) MB)"
        if panel.runModal() == .OK { add(panel.urls.map { .file($0) }) }
    }

    /// ⌘V with files or an image on the clipboard attaches them; plain text pastes as usual.
    func installPasteMonitor() {
        let window = model.window
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            // Only this window's composer: every open chat window installs its own monitor.
            guard e.window === window, e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  e.charactersIgnoringModifiers == "v",
                  let tv = e.window?.firstResponder as? NSTextView, !tv.isFieldEditor,
                  let items = Attachment.fromPasteboard(.general) else { return e }
            add(items)
            return nil
        }
    }

    func composer(_ c: Chat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(attachments) { a in
                            HStack(spacing: 4) {
                                Image(nsImage: a.thumbnail).resizable().scaledToFit().frame(width: 22, height: 22)
                                Text(a.name).font(.caption).lineLimit(1)
                                Button { attachments.removeAll { $0.id == a.id } } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        }
                    }
                }
            }
            if !attachError.isEmpty { Text(attachError).font(.caption).foregroundStyle(.red) }
            HStack(alignment: .bottom) {
            Button { pickFiles() } label: { Image(systemName: "paperclip").font(.title3) }
                .buttonStyle(.borderless)
                .help("Đính kèm file/ảnh (hoặc kéo thả, hoặc ⌘V ảnh/file đã copy)")
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
        }
        .padding(12)
        .background(dropTargeted ? Color.accentColor.opacity(0.08) : .clear)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { add([.file(url)]) }
                }
            }
            return true
        }
        .onAppear { installPasteMonitor() }
        .onDisappear { if let m = pasteMonitor { NSEvent.removeMonitor(m) } }
    }
}

struct MessageRow: View {
    let m: Message
    let root: URL

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
        let mine = m.kind == .user
        HStack(alignment: .top) {
            if mine { Spacer(minLength: 80) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                HStack {
                    Text(label).font(.caption.bold()).foregroundStyle(m.kind == .system ? Color.orange : .secondary)
                    Text(m.date, style: .time).font(.caption2).foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Group {
                        if [.task, .callback, .handoff].contains(m.kind) && m.text.count > 600 {
                            DisclosureGroup(String(m.text.prefix(160)) + "…") { body(m.text) }
                        } else {
                            body(m.text)
                        }
                    }
                    // Results relayed between agents are rarely read in full; keep them (and their collapsed preview) quiet.
                    .foregroundStyle(m.kind == .callback ? Color.secondary : .primary)
                    let images = Attachment.paths(in: m.text).compactMap { rel -> URL? in
                        let u = root.appendingPathComponent(rel)
                        return Attachment.isImage(u) ? u : nil
                    }
                    if !images.isEmpty {
                        HStack {
                            ForEach(images, id: \.self) { u in
                                Link(destination: u) {
                                    if let img = NSImage(contentsOf: u) {
                                        Image(nsImage: img).resizable().scaledToFit().frame(maxWidth: 160, maxHeight: 120)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(background))
            }
            if !mine { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity)
    }

    func body(_ text: String) -> some View {
        let md = linkifyPaths(text, root: root)
        return Text((try? AttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
            .textSelection(.enabled)
            .font(m.kind == .assistant || m.kind == .user ? .body : .callout)
    }

    var background: Color {
        switch m.kind {
        case .user: .accentColor.opacity(0.18)
        case .assistant: Color.secondary.opacity(0.08)
        case .system: .orange.opacity(0.08)
        default: .purple.opacity(0.06)
        }
    }
}

/// Provider + model + effort picker, used for agents, fallbacks and bulk replace.
struct ProfileEditor: View {
    @Binding var profile: Profile

    /// Models the CLI itself reported (Antigravity), so new ones appear without an app update; else the built-in list.
    func models(_ p: Provider) -> [String] {
        let live = Accounts.shared.status[p]?.models ?? []
        return live.isEmpty ? p.suggestedModels : live
    }

    var body: some View {
        HStack(spacing: 4) {
            Picker("", selection: $profile.provider) {
                ForEach(Provider.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().frame(width: 125)
            .onChange(of: profile.provider) { _, p in
                if !models(p).contains(profile.model) { profile.model = models(p).first ?? "" }
                if !p.efforts.contains(profile.effort) { profile.effort = "" }
            }
            TextField("", text: $profile.model, prompt: Text("model")).labelsHidden().frame(width: 160)
            Menu {
                ForEach(models(profile.provider), id: \.self) { m in Button(m) { profile.model = m } }
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
