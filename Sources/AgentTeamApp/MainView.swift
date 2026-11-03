import AgentTeamCore
import AppKit
import SwiftUI

enum Selection: Hashable {
    case team
    case chat(String)
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Bindable var o: Orchestrator
    @State private var selection: Selection? = .team
    @State private var confirmDelete = false
    @State private var confirmRemove = false
    @State private var removeRefusal: String?
    @State private var preview = PreviewState()
    @State private var nameDraft = ""
    @State private var collapsed: Set<String> = []
    @State private var searchShown = false
    @State private var focusMessage: UUID?
    @FocusState private var editingName: Bool

    var displayName: String { o.team.name ?? o.paths.workspace.lastPathComponent }

    /// Running, then waiting, then limited; otherwise the state of the bottom chat, the one seen last when expanded.
    func groupStatus(_ agentId: String) -> ChatStatus? {
        let cs = o.chats(of: agentId)
        for st in [ChatStatus.running, .queued, .limited] where cs.contains(where: { $0.status == st }) { return st }
        return cs.last?.status
    }

    func saveName() {
        let n = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        o.team.name = n.isEmpty || n == o.paths.workspace.lastPathComponent ? nil : n
        nameDraft = displayName
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                        // Display name only: the folder on disk is not renamed (running agents work inside it).
                        // Edits a draft and saves on Enter/leaving the field, so clearing it does not snap back to the old name.
                        TextField("", text: $nameDraft, prompt: Text(o.paths.workspace.lastPathComponent))
                            .textFieldStyle(.plain).font(.headline)
                            .focused($editingName)
                            .onSubmit { saveName() }
                            .onChange(of: editingName) { if !editingName { saveName() } }
                            .onAppear { nameDraft = displayName }
                            .help("Bấm để đổi tên hiển thị của dự án (thư mục trên ổ đĩa giữ nguyên)")
                        Button {
                            if let r = ProjectCleanup.refusal(workspace: o.paths.workspace) { removeRefusal = r } else { confirmRemove = true }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                            .help("Gỡ dự án: chuyển thư mục dự án và lịch sử phiên Claude/Codex/agy của nó vào Thùng rác")
                    }
                    Text(o.paths.workspace.path).font(.caption2).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                }
                .padding(.vertical, 4)
                NavigationLink(value: Selection.team) { Label("Team & Provider", systemImage: "person.3") }
                ForEach(o.team.agents) { agent in
                    // Plain Section: the whole name block toggles it, instead of the small disclosure arrow next to +.
                    Section {
                        if !collapsed.contains(agent.id) { ForEach(o.chats(of: agent.id)) { c in
                            NavigationLink(value: Selection.chat(c.id)) {
                                HStack(spacing: 6) {
                                    Circle().fill(c.status.color).frame(width: 8, height: 8)
                                    Text(c.title).lineLimit(1)
                                }
                            }
                            .contextMenu { Button("Xoá chat", role: .destructive) { o.deleteChat(c.id) } }
                        } }
                    } header: {
                        HStack {
                            HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text(o.team.role(agent.roleId)?.name ?? agent.roleId).font(.title3.bold())
                                    Text("· \(agent.id)")
                                }
                                HStack(spacing: 5) {
                                    // Collapsed: one dot for the group, the busiest state among its chats.
                                    if collapsed.contains(agent.id), let st = groupStatus(agent.id) {
                                        Circle().fill(st.color).frame(width: 7, height: 7)
                                    }
                                Text(o.team.effectiveProfile(for: agent)?.label ?? "không khả dụng")
                                    .font(.caption2).foregroundStyle(o.team.effectiveProfile(for: agent) == agent.profile ? Color.secondary : .orange)
                                }
                            }
                            Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if collapsed.contains(agent.id) { collapsed.remove(agent.id) } else { collapsed.insert(agent.id) }
                            }
                            .help(collapsed.contains(agent.id) ? "Bấm để mở danh sách chat" : "Bấm để thu gọn")
                            Button {
                                selection = .chat(o.newChat(agentId: agent.id, title: Chat.untitled))
                            } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderless)
                            .help("Chat mới với agent này")
                        }
                    }
                    // The sidebar list adds its own hover chevron to section headers; the name block toggles instead.
                    .collapsible(false)
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 270)
        } detail: {
            VStack(spacing: 0) {
                if !o.online {
                    HStack {
                        Image(systemName: "wifi.slash").foregroundStyle(.orange)
                        Text("Mất kết nối mạng. Việc bị gián đoạn sẽ tự chạy lại khi có mạng.").font(.caption)
                        Spacer()
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.15))
                }
                if let err = o.lastIOError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        Text(err).font(.caption).lineLimit(2)
                        Spacer()
                        Button("Đóng") { o.clearLastIOError() }
                            .buttonStyle(.borderless)
                    }
                    .padding(8)
                    .background(Color.red.opacity(0.15))
                }
                if !o.loadErrors.isEmpty {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Có \(o.loadErrors.count) tệp chat không đọc được (giữ nguyên tệp gốc): \(o.failedChatFiles.joined(separator: ", "))")
                            .font(.caption).lineLimit(2)
                        Spacer()
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.15))
                }
                Group {
                    switch selection {
                    case .chat(let id): ChatView(o: o, chatId: id, focus: focusMessage).id(id)
                    default: TeamView(o: o, openChat: { selection = .chat($0) })
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { QuotaBar(o: o) }
        }
        .environment(preview)
        .task { if Accounts.shared.status.isEmpty { await Accounts.shared.refresh(o.team.binaryPaths) } }
        .inspector(isPresented: $preview.shown) {
            PreviewPane(root: o.paths.workspace)
                .environment(preview)
                .inspectorColumnWidth(min: 280, ideal: 460, max: 1000)
        }
        .confirmationDialog("Gỡ dự án \(displayName)?", isPresented: $confirmRemove) {
            Button("Gỡ dự án", role: .destructive) { model.removeProject() }
        } message: {
            Text("Chuyển vào Thùng rác: cả thư mục \(o.paths.workspace.path) (mã nguồn, .agentteam, graphify-out) và lịch sử phiên Claude Code, Codex, Antigravity mà dự án này đã chạy. Dự án khác không bị đụng tới. Dung lượng được trả lại khi bạn dọn Thùng rác; trước đó vẫn khôi phục được.")
        }
        .alert("Không gỡ được dự án", isPresented: Binding(get: { removeRefusal != nil }, set: { if !$0 { removeRefusal = nil } })) {
            Button("OK") {}
        } message: { Text(removeRefusal ?? "") }
        .confirmationDialog("Xoá dữ liệu Agent Team của \(o.paths.workspace.lastPathComponent)?", isPresented: $confirmDelete) {
            Button("Chuyển vào Thùng rác", role: .destructive) { model.deleteProjectData() }
        } message: {
            Text("Chuyển thư mục \(o.paths.root.path) (team, lịch sử chat, ghi chú, quyết định) vào Thùng rác và gỡ dự án khỏi danh sách. Mã nguồn và các file khác của dự án KHÔNG bị đụng tới. Khôi phục được từ Thùng rác.")
        }
        .navigationTitle(displayName)
        .navigationSubtitle(o.paths.workspace.path)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { searchShown.toggle() } label: { Label("Tìm", systemImage: "magnifyingglass") }
                    .keyboardShortcut("f", modifiers: .command)
                    .help("Tìm theo từ khoá trong mọi chat của dự án (⌘F)")
                    .popover(isPresented: $searchShown, arrowEdge: .bottom) {
                        SearchPanel(o: o) { hit in
                            focusMessage = hit.messageId
                            selection = .chat(hit.chatId)
                            searchShown = false
                        }
                    }
            }
            ToolbarItem(placement: .primaryAction) {
                Text("\(o.runningCount) đang chạy · \(o.chats.filter { $0.status == .queued }.count) chờ · \(o.totalTokens.formatted()) token")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { preview.shown.toggle() } label: { Label("Xem trước", systemImage: "sidebar.right") }
                    .help("Bật/tắt khung xem trước file (ảnh, PDF, báo cáo…)")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Mở dự án trong tab mới…") {
                        if let url = AppModel.pickFolder() { openWindow(value: url.standardizedFileURL.path) }
                    }
                    Menu("Gần đây (tab mới)") {
                        ForEach(AppModel.recent.filter { $0 != o.paths.workspace.standardizedFileURL.path }, id: \.self) { p in
                            Button(AppModel.displayName(p)) { openWindow(value: p) }
                        }
                    }
                    Button("Đổi dự án ở tab này…") { model.chooseWorkspace() }
                    Button("Hiện trong Finder") { NSWorkspace.shared.activateFileViewerSelecting([o.paths.workspace]) }
                    Divider()
                    Button("Đóng dự án") { model.close() }
                    Button("Xoá dữ liệu Agent Team của dự án…", role: .destructive) { confirmDelete = true }
                } label: { Label("Dự án", systemImage: "folder") }
                .help("Đang mở: \(o.paths.workspace.path). Mở song song dự án khác: ⌘O.")
            }
        }
    }
}

/// Keyword search across the project's chats; picking a hit opens that chat at the message.
struct SearchPanel: View {
    let o: Orchestrator
    let onPick: (ChatSearch.Hit) -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        let hits = ChatSearch.find(query, in: o.chats)
        VStack(alignment: .leading, spacing: 8) {
            TextField("Tìm trong mọi chat (không phân biệt dấu)", text: $query)
                .textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { if let h = hits.first { onPick(h) } }
            if query.trimmingCharacters(in: .whitespaces).count >= 2 {
                Text(hits.isEmpty ? "Không tìm thấy" : "\(hits.count)\(hits.count == 200 ? "+" : "") kết quả")
                    .font(.caption).foregroundStyle(.secondary)
            }
            List(hits) { h in
                Button { onPick(h) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(label(h)).font(.caption.bold()).lineLimit(1)
                            Spacer()
                            if let d = h.date { Text(d, format: .dateTime.day().month().hour().minute()).font(.caption2).foregroundStyle(.tertiary) }
                        }
                        Text(h.snippet).font(.callout).lineLimit(3).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .padding(12)
        .frame(width: 460, height: 420)
        .onAppear { focused = true }
    }

    func label(_ h: ChatSearch.Hit) -> String {
        let c = o.chat(h.chatId)
        let role = c.flatMap { o.team.agent($0.agentId) }.flatMap { o.team.role($0.roleId) }?.name ?? ""
        return "\(role) · \(c?.title ?? h.chatId)"
    }
}
