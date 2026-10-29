import AgentTeamCore
import AppKit
import SwiftUI

struct TeamView: View {
    @Environment(AppModel.self) private var model
    @Bindable var o: Orchestrator
    @State private var newAgentRole = "worker"
    @State private var bulkFrom: Provider = .claude
    @State private var bulkTo = Profile(.codex, "gpt-6.1-sol")
    @State private var newRoleName = ""
    @State private var pendingSetup: (title: String, setup: TeamSetup)?
    private var accounts: Accounts { Accounts.shared }

    var body: some View {
        Form {
            providers
            presets
            agents
            bulk
            roles
            operations
        }
        .formStyle(.grouped)
        .task { await accounts.refresh(o.team.binaryPaths) }
        .confirmationDialog("Chuyển sang bộ \(pendingSetup?.title ?? "")?", isPresented: Binding(
            get: { pendingSetup != nil }, set: { if !$0 { pendingSetup = nil } })) {
            Button("Chuyển, bỏ thay đổi chưa lưu", role: .destructive) {
                if let s = pendingSetup { o.applySetup(s.setup) }
                pendingSetup = nil
            }
        } message: {
            Text("Team hiện tại có thay đổi chưa lưu. Bấm \"Lưu Custom\" trước nếu muốn giữ lại.")
        }
    }

    /// Green: signed in · orange: hit its limit · red: CLI missing or signed out · grey: off or not checked yet.
    func statusColor(_ p: Provider) -> Color {
        if o.team.disabledProviders.contains(p) { return .gray }
        if o.team.limitedProviders.contains(p) { return .orange }
        switch accounts.status[p]?.ok {
        case true?: return .green
        case false?: return .red
        case nil: return .gray
        }
    }

    func openTerminal(_ p: Provider, login: Bool) {
        guard let bin = model.runner.binary(for: p, override: o.team.binaryPaths[p.rawValue]) else { return }
        // A .command file opens in Terminal without asking for permission to control Terminal.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("agentteam-\(p.rawValue)-\(login ? "login" : "logout").command")
        try? "#!/bin/zsh\n\(p.accountCommand(bin, login: login))\n".write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        NSWorkspace.shared.open(file)
        accounts.watch(p, o.team.binaryPaths)
    }

    var providers: some View {
        Section("Provider (tắt provider hết hạn → agent tự dùng fallback của vai trò)") {
            ForEach(Provider.allCases) { p in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle().fill(statusColor(p)).frame(width: 10, height: 10)
                            .help(o.team.limitedProviders.contains(p) ? "Đang bị limit" : accounts.status[p]?.detail ?? "Đang kiểm tra…")
                        Text(p.title).bold()
                        if o.team.limitedProviders.contains(p) {
                            Button("Bỏ đánh dấu limit") { o.clearLimit(p) }
                            .tint(.orange)
                        }
                        Spacer()
                        Button("Login") { openTerminal(p, login: true) }
                            .help("Mở Terminal để đăng nhập (đổi tài khoản: Logout rồi Login).")
                        Button("Logout") { openTerminal(p, login: false) }
                        Spacer()
                        Toggle("Đang dùng", isOn: Binding(
                            get: { !o.team.disabledProviders.contains(p) },
                            set: { on in if on { o.team.disabledProviders.remove(p) } else { o.team.disabledProviders.insert(p) } }))
                        .labelsHidden()
                    }
                    HStack {
                        if let path = model.runner.binary(for: p, override: o.team.binaryPaths[p.rawValue]) {
                            Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        } else if inUse(p) {
                            Text("không tìm thấy `\(p.binaryName)` — đang có vị trí dùng provider này").font(.caption).foregroundStyle(.red)
                        } else {
                            Text("chưa cài `\(p.binaryName)` (không bắt buộc, chưa có vị trí nào dùng)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        TextField("", text: Binding(
                            get: { o.team.binaryPaths[p.rawValue] ?? "" },
                            set: { o.team.binaryPaths[p.rawValue] = $0.isEmpty ? nil : $0 }), prompt: Text("đường dẫn tuỳ chỉnh"))
                        .labelsHidden().frame(width: 220)
                        Button("Chọn…") { pickBinary(p) }
                    }
                }
            }
        }
    }

    func inUse(_ p: Provider) -> Bool {
        !o.team.disabledProviders.contains(p)
            && (o.team.agents.contains { $0.profile.provider == p } || o.team.roles.contains { $0.fallbacks.contains { $0.provider == p } })
    }

    func pickBinary(_ p: Provider) {
        let panel = NSOpenPanel()
        panel.message = "Chọn file lệnh `\(p.binaryName)` (vd. ~/.local/bin/\(p.binaryName)). Nhấn ⌘⇧. để hiện thư mục ẩn."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { o.team.binaryPaths[p.rawValue] = url.path }
    }

    var presets: some View {
        Section {
            let current = o.team.preset
            let dirty = current == nil && o.team.customSetup.map { !$0.sameShape(as: o.team.setup) } ?? true
            HStack {
                Picker("Bộ mẫu team", selection: Binding(
                    get: { current?.rawValue ?? "custom" },
                    set: { id in
                        let target: (String, TeamSetup)?
                        if let p = TeamPreset(rawValue: id) { target = (p.title, p.setup) }
                        else { target = o.team.customSetup.map { ("Custom", $0) } }
                        guard let target else { return }
                        if dirty { pendingSetup = target } else { o.applySetup(target.1) }
                    })) {
                    ForEach(TeamPreset.allCases) { Text($0.title).tag($0.rawValue) }
                    if o.team.customSetup != nil || current == nil {
                        Text(dirty ? "Custom (chưa lưu)" : "Custom").tag("custom")
                    }
                }
                .disabled(o.runningCount > 0)
                Button("Lưu Custom") { o.team.customSetup = o.team.setup }
                    .disabled(!dirty)
                    .help("Lưu vai trò và vị trí hiện tại thành bản Custom của riêng dự án này.")
            }
            if o.runningCount > 0 {
                Text("Đang có agent chạy; dừng hoặc chờ xong rồi mới đổi bộ mẫu.").font(.caption).foregroundStyle(.secondary)
            }
        } footer: {
            Text("Chỉ áp dụng cho dự án này. Sửa vai trò/vị trí sẽ thành Custom; dự án khác không bị ảnh hưởng.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    var agents: some View {
        Section("Vị trí (agent) — chọn nhanh provider / model / effort") {
            ForEach($o.team.agents) { $agent in
                VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(o.team.role(agent.roleId)?.name ?? agent.roleId).bold()
                    Text(agent.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    if let e = o.team.effectiveProfile(for: agent) {
                        if e != agent.profile { Text("→ \(e.label)").font(.caption).foregroundStyle(.orange) }
                    } else {
                        Text("không khả dụng").font(.caption).foregroundStyle(.red)
                    }
                    let used = !o.chats(of: agent.id).isEmpty
                    // Read the id before mutating: reading `agent` inside removeAll re-enters `team` (exclusivity crash).
                    let id = agent.id
                    Button { o.team.agents.removeAll { $0.id == id } } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).disabled(used)
                        .help(used ? "Agent đã có chat; xoá các chat trước." : "Xoá agent")
                }
                ProfileEditor(profile: $agent.profile)
                }
            }
            HStack {
                Picker("Thêm agent cho vai trò", selection: $newAgentRole) {
                    ForEach(o.team.roles) { Text($0.name).tag($0.id) }
                }
                .frame(width: 320)
                Button("Thêm") {
                    let base = o.team.agents.first { $0.roleId == newAgentRole }?.profile ?? Profile(.codex)
                    o.team.agents.append(Agent(roleId: newAgentRole, profile: base))
                }
            }
        }
    }

    var bulk: some View {
        Section("Đổi hàng loạt") {
            HStack {
                Text("Mọi agent đang dùng")
                Picker("", selection: $bulkFrom) {
                    ForEach(Provider.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 130)
                Text("chuyển sang")
                Spacer()
            }
            HStack {
                ProfileEditor(profile: $bulkTo)
                Spacer()
                Button("Áp dụng") { o.replaceProvider(bulkFrom, with: bulkTo) }
            }
        }
    }

    var roles: some View {
        Section("Vai trò (hợp đồng công việc — đổi nhân sự không đổi hợp đồng)") {
            ForEach($o.team.roles) { $role in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Tên", text: $role.name)
                        HStack {
                            Picker("Quyền", selection: $role.access) {
                                ForEach(Access.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .frame(width: 220)
                            Toggle("Quyền điều phối (giao việc cho agent khác)", isOn: $role.canDispatch)
                                .help("Bật: vai trò này được chạy `agentteam dispatch` để giao việc. Thường chỉ bật cho Lead; bật cho nhiều vai trò dễ sinh việc chồng chéo và tốn token. Tắt không ảnh hưởng việc vai trò này NHẬN việc.")
                        }
                        Text("Hợp đồng vai trò").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $role.contract).font(.callout).frame(height: 90)
                            .scrollContentBackground(.hidden).padding(4)
                            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                        Text("Fallback khi provider của agent bị tắt/limit (theo thứ tự)").font(.caption).foregroundStyle(.secondary)
                        ForEach(role.fallbacks.indices, id: \.self) { i in
                            HStack {
                                Text("\(i + 1).").foregroundStyle(.secondary)
                                // Bounds-checked: a removed row may still be read once by SwiftUI.
                                ProfileEditor(profile: Binding(
                                    get: { i < $role.wrappedValue.fallbacks.count ? $role.wrappedValue.fallbacks[i] : Profile(.codex) },
                                    set: { if i < $role.wrappedValue.fallbacks.count { $role.wrappedValue.fallbacks[i] = $0 } }))
                                Button { role.fallbacks.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                            }
                        }
                        Button("Thêm fallback") { role.fallbacks.append(Profile(.antigravity, "gemini-3.8-flash-high")) }
                    }
                    .padding(.vertical, 4)
                } label: {
                    HStack {
                        Text(role.name).bold()
                        Text("\(role.access.title)\(role.canDispatch ? " · giao việc" : "") · \(role.fallbacks.count) fallback")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                TextField("Tên vai trò mới (vd. Reviewer)", text: $newRoleName)
                Button("Thêm vai trò") {
                    let id = newRoleName.lowercased().filter { $0.isLetter || $0.isNumber }
                    guard !id.isEmpty, o.team.role(id) == nil else { return }
                    let role = Role(id: id, name: newRoleName, contract: "Mô tả nhiệm vụ, phạm vi và cách báo cáo.", access: .readOnly,
                                    fallbacks: o.team.role("worker")?.fallbacks ?? [])
                    o.team.roles.append(role)
                    newRoleName = ""
                }
            }
        }
    }

    var operations: some View {
        Section("Vận hành & tiết kiệm token") {
            Toggle("Tự động chuyển sang fallback khi bị limit (kèm gói bàn giao)", isOn: $o.team.autoFailover)
            Stepper("Thử lại provider bị limit sau: \(o.team.limitCooldownMinutes) phút", value: $o.team.limitCooldownMinutes, in: 5...300, step: 5)
            Stepper("Số agent chạy song song tối đa: \(o.team.maxConcurrent)", value: $o.team.maxConcurrent, in: 1...8)
            Stepper("Độ dài kết quả chuyển về người giao: \(o.team.callbackLimit) ký tự", value: $o.team.callbackLimit, in: 500...20000, step: 500)
            Stepper("Số vòng phản biện Planner ↔ Critic tối đa: \(o.team.debateRounds ?? 2)",
                    value: Binding(get: { o.team.debateRounds ?? 2 }, set: { o.team.debateRounds = $0 }), in: 1...10)
                .help("Lead dùng con số này cho việc cần thảo luận. Bạn cũng có thể ghi riêng trong tin nhắn, ví dụ \"thảo luận 5 vòng\".")
            Stepper("Lượt tự động liên tiếp tối đa mỗi chat: \(o.team.maxAutoTurns)", value: $o.team.maxAutoTurns, in: 1...50)
            Stepper("Số lần giao việc tối đa mỗi lượt: \(o.team.maxDispatchPerTurn)", value: $o.team.maxDispatchPerTurn, in: 1...20)
            Stepper("Coi là treo khi không có tín hiệu: \(o.team.stallMinutes ?? 20) phút",
                    value: Binding(get: { o.team.stallMinutes ?? 20 }, set: { o.team.stallMinutes = $0 }), in: 5...120, step: 5)
                .help("Agent không in ra gì trong thời gian này (thường do một lệnh/test chạy mãi) thì app dừng nó cùng các lệnh con, chạy lại một lần kèm cảnh báo; treo lần nữa thì báo lỗi. Rớt mạng thì tự thử lại khi có mạng.")
        }
    }
}

/// Sign-in state of each provider CLI; account-wide, so shared by all windows.
@MainActor @Observable
final class Accounts {
    static let shared = Accounts()
    var status: [Provider: AccountStatus] = [:]
    @ObservationIgnored var watching: [Provider: Task<Void, Never>] = [:]

    func refresh(_ paths: [String: String]) async {
        for p in Provider.allCases {
            status[p] = await AppModel.runner.accountStatus(p, override: paths[p.rawValue])
        }
    }

    /// After Login/Logout opens Terminal: re-check every 5 s for 3 minutes so the light follows the sign-in.
    func watch(_ p: Provider, _ paths: [String: String]) {
        watching[p]?.cancel()
        let before = status[p]
        watching[p] = Task {
            for _ in 0..<36 {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
                let s = await AppModel.runner.accountStatus(p, override: paths[p.rawValue])
                status[p] = s
                if s.ok != before?.ok { return }
            }
        }
    }
}
