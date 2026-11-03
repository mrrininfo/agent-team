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
    @State private var addingKey: Provider?
    @AppStorage("teamDetailsShown") private var detailsShown = false
    /// Opens a chat from the pipeline board.
    var openChat: (String) -> Void = { _ in }
    private var accounts: Accounts { Accounts.shared }

    var body: some View {
        Form {
            overview
            pipeline
            providers
            presets
            Section {
                Button(detailsShown ? "Ẩn cài đặt chi tiết" : "Cài đặt chi tiết: vị trí, đổi hàng loạt, hợp đồng vai trò, vận hành…") {
                    detailsShown.toggle()
                }
                .buttonStyle(.link)
            }
            if detailsShown {
                agents
                bulk
                roles
                operations
            }
        }
        .formStyle(.grouped)
        .task { await accounts.refresh(o.team.binaryPaths) }
        .sheet(item: $addingKey) { p in AddKeySheet(provider: p) { accounts.add($0, key: $1) } }
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

    /// `account` nil = the CLI's own login; else that extra account's config folder is exported first.
    func openTerminal(_ p: Provider, login: Bool, account: String? = nil) {
        guard let bin = model.runner.binary(for: p, override: o.team.binaryPaths[p.rawValue]) else { return }
        // A .command file opens in Terminal without asking for permission to control Terminal.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("agentteam-\(p.rawValue)-\(account ?? "main")-\(login ? "login" : "logout").command")
        let exports = AccountStore.environment(account).map { "export \($0.key)='\($0.value.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n")
        try? "#!/bin/zsh\n\(exports)\n\(p.accountCommand(bin, login: login))\n".write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        NSWorkspace.shared.open(file)
        if let account { accounts.watchAccount(account, p, o.team.binaryPaths) } else { accounts.watch(p, o.team.binaryPaths) }
    }

    /// Further accounts of one provider, tried in this order after the default one hits its limit.
    @ViewBuilder func extraAccounts(_ p: Provider) -> some View {
        ForEach(accounts.list.filter { $0.provider == p }) { a in
            HStack(spacing: 6) {
                Circle().fill(accountColor(a)).frame(width: 8, height: 8)
                    .help(o.team.limitedAccounts?[a.id].map { "Đang bị limit, tự thử lại lúc \($0.formatted(date: .abbreviated, time: .shortened))" }
                          ?? (a.kind == .apiKey ? "API key" : accounts.extraStatus[a.id]?.detail ?? "Đang kiểm tra…"))
                TextField("", text: Binding(get: { a.label }, set: { v in accounts.update(a.id) { $0.label = v } }))
                    .textFieldStyle(.plain).frame(width: 140)
                Text(a.kind == .login ? "đăng nhập" : (a.baseURL ?? "").isEmpty ? "API key" : "API · \(a.baseURL!)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if a.kind == .apiKey {
                    TextField("", value: Binding(get: { a.dailyTokenCap }, set: { v in accounts.update(a.id) { $0.dailyTokenCap = v } }),
                              format: .number, prompt: Text("token/ngày"))
                        .labelsHidden().frame(width: 90)
                        .help("Tối đa bấy nhiêu token mỗi ngày rồi tạm nghỉ tới 0 giờ (để trống = không giới hạn)")
                }
                Spacer()
                if a.kind == .login {
                    Button("Login") { openTerminal(p, login: true, account: a.id) }
                    Button("Logout") { openTerminal(p, login: false, account: a.id) }
                }
                Button { accounts.move(a.id, by: -1) } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless)
                    .help("Dùng trước tài khoản phía trên")
                Button { accounts.remove(a.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    .help("Xoá tài khoản này (thư mục đăng nhập và key của nó)")
                Toggle("", isOn: Binding(get: { a.enabled }, set: { v in accounts.update(a.id) { $0.enabled = v } })).labelsHidden()
            }
            .padding(.leading, 18)
        }
        HStack {
            Button("+ Đăng nhập tài khoản khác") { openTerminal(p, login: true, account: accounts.add(Account(provider: p, label: "\(p.title) \(accounts.list.filter { $0.provider == p }.count + 2)", kind: .login), key: nil)) }
            if p != .antigravity { Button("+ Thêm API key") { addingKey = p } }
        }
        .buttonStyle(.link).font(.caption).padding(.leading, 18)
    }

    func accountColor(_ a: Account) -> Color {
        if !a.enabled || o.team.disabledProviders.contains(a.provider) { return .gray }
        if o.team.limitedAccounts?[a.id] != nil { return .orange }
        if a.kind == .apiKey { return .green }
        switch accounts.extraStatus[a.id]?.ok {
        case true?: return .green
        case false?: return .red
        case nil: return .gray
        }
    }

    var providers: some View {
        Section("Provider (tắt provider hết hạn → agent tự dùng fallback của vai trò)") {
            if let bad = o.team.badModels, !bad.isEmpty {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Model bị CLI từ chối, đang bỏ qua: \(bad.sorted().map { $0.replacingOccurrences(of: "|", with: " · ") }.joined(separator: ", ")). Đổi tên model ở vị trí/fallback rồi bỏ đánh dấu.")
                        .font(.caption)
                    Spacer()
                    Button("Bỏ đánh dấu model lỗi") { o.team.badModels = nil; o.retryLimited() }
                }
            }
            if let lm = o.team.limitedModels, !lm.isEmpty {
                HStack {
                    Image(systemName: "hourglass").foregroundStyle(.orange)
                    Text("Model hết quota, đang dùng fallback: " + lm.sorted { $0.key < $1.key }.map {
                        "\($0.key.replacingOccurrences(of: "|", with: " · ")) (tới \($0.value.formatted(date: .omitted, time: .shortened)))"
                    }.joined(separator: ", "))
                        .font(.caption)
                    Spacer()
                    Button("Thử lại ngay") { o.team.limitedModels = nil; o.retryLimited() }
                }
            }
            ForEach(Provider.allCases) { p in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle().fill(statusColor(p)).frame(width: 10, height: 10)
                            .help(o.team.limitedProviders.contains(p)
                                  ? "Đang bị limit" + (o.team.limitedUntil?[p.rawValue].map { ", tự thử lại lúc \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
                                  : accounts.status[p]?.detail ?? "Đang kiểm tra…")
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
                    extraAccounts(p)
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

    /// One card per seat: who it is, what it does, which model runs it now, and how it is doing.
    var overview: some View {
        Section("Đội") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                ForEach(o.team.agents) { agent in
                    let role = o.team.role(agent.roleId)
                    let eff = o.team.effectiveProfile(for: agent)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Circle().fill(seatStatus(agent.id)?.color ?? .gray).frame(width: 8, height: 8)
                            Text(role?.name ?? agent.roleId).bold()
                            Spacer()
                            Text(role?.access.title ?? "").font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(role.map { Self.firstSentence($0.contract) } ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text(eff?.label ?? "không khả dụng").font(.caption.monospaced())
                            .foregroundStyle(eff == nil ? Color.red : eff == agent.profile ? .primary : .orange).lineLimit(1)
                        if let fb = role?.fallbacks, !fb.isEmpty {
                            Text("dự phòng: " + fb.map(\.label).joined(separator: " → ")).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
                }
            }
        }
    }

    /// Active chats by step of the flow; click one to open it.
    var pipeline: some View {
        Section("Luồng việc") {
            let active = o.chats.compactMap { c in PipelineStage.of(c, team: o.team).map { (c, $0) } }
            HStack(alignment: .top, spacing: 8) {
                ForEach(PipelineStage.allCases) { stage in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(stage.title).font(.caption.bold()).foregroundStyle(.secondary)
                        let items = active.filter { $0.1 == stage }.map(\.0)
                        if items.isEmpty { Text("—").font(.caption).foregroundStyle(.tertiary) }
                        ForEach(items) { c in
                            Button { openChat(c.id) } label: {
                                HStack(spacing: 4) {
                                    Circle().fill(c.status.color).frame(width: 6, height: 6)
                                    Text(c.title).font(.caption).lineLimit(2).multilineTextAlignment(.leading)
                                }
                            }
                            .buttonStyle(.plain)
                            .help("Mở chat \(c.id)")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    func seatStatus(_ agentId: String) -> ChatStatus? {
        let cs = o.chats(of: agentId)
        for st in [ChatStatus.running, .queued, .limited] where cs.contains(where: { $0.status == st }) { return st }
        return cs.last?.status
    }

    static func firstSentence(_ s: String) -> String {
        let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
        return line.firstIndex(of: ".").map { String(line[...$0]) } ?? line
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
            Stepper(o.team.compactAt == 0 ? "Tự nén context: tắt" : "Tự nén context khi vượt: \(o.team.compactAt)% cửa sổ model",
                    value: Binding(get: { o.team.compactAt }, set: { o.team.compactPercent = $0 }), in: 0...90, step: 10)
                .help("Chỉ chạy giữa các lượt, không ngắt việc đang chạy. Claude: chạy /compact ngầm khi chat rảnh. Codex: tự nén khi chạm ngưỡng. Antigravity không có lệnh nén: lượt sau mở phiên mới kèm gói bàn giao. 0 = tắt.")
            Toggle("Critic kiểm tra đáp án cuối của Lead khớp đề bài", isOn: Binding(get: { o.team.goalCheckOn }, set: { o.team.goalCheck = $0 }))
                .help("Khi Lead trả lời xong một đề bài có giao việc, Critic chấm từng tiêu chí. Đạt: chỉ ghi chú, không tốn lượt Lead. Không đạt: Lead sửa đáp án một lần. Tốn thêm 1 lượt Critic mỗi đáp án cuối.")
        }
    }
}

/// Sign-in state of each provider CLI; account-wide, so shared by all windows.
@MainActor @Observable
final class Accounts {
    static let shared = Accounts()
    var status: [Provider: AccountStatus] = [:]
    @ObservationIgnored var watching: [Provider: Task<Void, Never>] = [:]

    /// Mirror of `AccountStore.accounts` so the UI redraws when it changes.
    var list: [Account] = AccountStore.accounts
    var extraStatus: [String: AccountStatus] = [:]

    func refresh(_ paths: [String: String]) async {
        for p in Provider.allCases {
            status[p] = await AppModel.runner.accountStatus(p, override: paths[p.rawValue])
        }
        for a in list where a.kind == .login {
            extraStatus[a.id] = await AppModel.runner.accountStatus(a.provider, override: paths[a.provider.rawValue], account: a.id)
        }
    }

    private func commit(_ new: [Account]) {
        AccountStore.accounts = new
        AccountStore.save()
        list = new
    }

    /// Adds the account (and stores its key in the Keychain); returns its id.
    @discardableResult func add(_ a: Account, key: String?) -> String {
        commit(list + [a])
        if let key, !key.isEmpty {
            Keychain.save(key, for: a.id)
            // Codex reads its key from CODEX_HOME/auth.json: sign that folder in with the key once.
            if a.provider == .codex, let bin = AppModel.runner.binary(for: .codex, override: nil) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: bin)
                p.arguments = ["login", "--with-api-key"]
                p.environment = ProcessInfo.processInfo.environment.merging(AccountStore.environment(a.id)) { $1 }
                let inp = Pipe()
                p.standardInput = inp
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                if (try? p.run()) != nil {
                    try? inp.fileHandleForWriting.write(contentsOf: Data((key + "\n").utf8))
                    try? inp.fileHandleForWriting.close()
                }
            }
        }
        return a.id
    }

    func update(_ id: String, _ f: (inout Account) -> Void) {
        var new = list
        guard let i = new.firstIndex(where: { $0.id == id }) else { return }
        f(&new[i])
        commit(new)
    }

    func remove(_ id: String) {
        AccountStore.remove(id)
        list = AccountStore.accounts
    }

    /// Moves the account up among those of its provider.
    func move(_ id: String, by d: Int) {
        var new = list
        guard let i = new.firstIndex(where: { $0.id == id }),
              let j = (d < 0 ? new[..<i].lastIndex { $0.provider == new[i].provider } : new[(i + 1)...].firstIndex { $0.provider == new[i].provider })
        else { return }
        new.swapAt(i, j)
        commit(new)
    }

    /// After an extra account's Login/Logout: re-check every 5 s for 3 minutes.
    func watchAccount(_ id: String, _ p: Provider, _ paths: [String: String]) {
        Task {
            let before = extraStatus[id]?.ok
            for _ in 0..<36 {
                try? await Task.sleep(for: .seconds(5))
                let s = await AppModel.runner.accountStatus(p, override: paths[p.rawValue], account: id)
                extraStatus[id] = s
                if s.ok != before { return }
            }
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


/// New API-key account; for Claude Code it can point at another Anthropic-compatible service (e.g. Muse on Meta's Model API).
struct AddKeySheet: View {
    let provider: Provider
    let onAdd: (Account, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var key = ""
    @State private var baseURL = ""
    @State private var cap: Int?

    var body: some View {
        Form {
            Text("Thêm API key cho \(provider.title)").font(.headline)
            TextField("Tên hiển thị", text: $label, prompt: Text(provider == .claude ? "vd. Anthropic API, Muse" : "vd. OpenAI API"))
            SecureField("API key", text: $key)
            if provider == .claude {
                TextField("Máy chủ (để trống = Anthropic)", text: $baseURL, prompt: Text("https://api.meta.ai"))
                Button("Điền sẵn cho Muse (Meta Model API)") {
                    baseURL = "https://api.meta.ai"
                    if label.isEmpty { label = "Muse" }
                }
                .buttonStyle(.link)
                Text("Có máy chủ riêng thì tài khoản không tự xoay vòng: chọn nó ở ô tài khoản của vị trí/fallback và điền model của dịch vụ đó (vd. muse-spark-1.2).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField("Token tối đa mỗi ngày", value: $cap, format: .number, prompt: Text("để trống = không giới hạn"))
            Text("Dùng API là trả tiền theo token: nên đặt giới hạn khi chạy qua đêm. Key được cất trong Keychain của macOS.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Huỷ") { dismiss() }
                Button("Thêm") {
                    let url = baseURL.trimmingCharacters(in: .whitespaces)
                    onAdd(Account(provider: provider, label: label.isEmpty ? "\(provider.title) API" : label, kind: .apiKey,
                                  baseURL: url.isEmpty ? nil : url, dailyTokenCap: cap), key.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}
