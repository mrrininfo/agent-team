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
    @State private var preview = PreviewState()

    var displayName: String { o.team.name ?? o.paths.workspace.lastPathComponent }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                        // Display name only: the folder on disk is not renamed (running agents work inside it).
                        TextField("", text: Binding(get: { displayName },
                                                    set: { o.team.name = $0.isEmpty || $0 == o.paths.workspace.lastPathComponent ? nil : $0 }),
                                  prompt: Text(o.paths.workspace.lastPathComponent))
                            .textFieldStyle(.plain).font(.headline)
                            .help("Bấm để đổi tên hiển thị của dự án (thư mục trên ổ đĩa giữ nguyên)")
                    }
                    Text(o.paths.workspace.path).font(.caption2).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                }
                .padding(.vertical, 4)
                NavigationLink(value: Selection.team) { Label("Team & Provider", systemImage: "person.3") }
                ForEach(o.team.agents) { agent in
                    Section {
                        ForEach(o.chats(of: agent.id)) { c in
                            NavigationLink(value: Selection.chat(c.id)) {
                                HStack(spacing: 6) {
                                    Circle().fill(c.status.color).frame(width: 8, height: 8)
                                    Text(c.title).lineLimit(1)
                                }
                            }
                            .contextMenu { Button("Xoá chat", role: .destructive) { o.deleteChat(c.id) } }
                        }
                    } header: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(o.team.role(agent.roleId)?.name ?? agent.roleId) · \(agent.id)")
                                Text(o.team.effectiveProfile(for: agent)?.label ?? "không khả dụng")
                                    .font(.caption2).foregroundStyle(o.team.effectiveProfile(for: agent) == agent.profile ? Color.secondary : .orange)
                            }
                            Spacer()
                            Button {
                                selection = .chat(o.newChat(agentId: agent.id, title: "Chat mới"))
                            } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderless)
                            .help("Chat mới với agent này")
                        }
                    }
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
                    case .chat(let id): ChatView(o: o, chatId: id).id(id)
                    default: TeamView(o: o)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { QuotaBar(o: o) }
        }
        .environment(preview)
        .inspector(isPresented: $preview.shown) {
            PreviewPane(root: o.paths.workspace)
                .environment(preview)
                .inspectorColumnWidth(min: 280, ideal: 460, max: 1000)
        }
        .confirmationDialog("Xoá dữ liệu Agent Team của \(o.paths.workspace.lastPathComponent)?", isPresented: $confirmDelete) {
            Button("Chuyển vào Thùng rác", role: .destructive) { model.deleteProjectData() }
        } message: {
            Text("Chuyển thư mục \(o.paths.root.path) (team, lịch sử chat, ghi chú, quyết định) vào Thùng rác và gỡ dự án khỏi danh sách. Mã nguồn và các file khác của dự án KHÔNG bị đụng tới. Khôi phục được từ Thùng rác.")
        }
        .navigationTitle(displayName)
        .navigationSubtitle(o.paths.workspace.path)
        .toolbar {
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
                    Button("Mở dự án trong cửa sổ mới…") {
                        if let url = AppModel.pickFolder() { openWindow(value: url.standardizedFileURL.path) }
                    }
                    Menu("Gần đây (cửa sổ mới)") {
                        ForEach(AppModel.recent.filter { $0 != o.paths.workspace.standardizedFileURL.path }, id: \.self) { p in
                            Button(AppModel.displayName(p)) { openWindow(value: p) }
                        }
                    }
                    Button("Đổi dự án ở cửa sổ này…") { model.chooseWorkspace() }
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
