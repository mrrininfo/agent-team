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
    @State private var templateNote = ""

    var body: some View {
        Form {
            providers
            agents
            bulk
            roles
            operations
            template
        }
        .formStyle(.grouped)
    }

    var providers: some View {
        Section("Provider (tắt provider hết hạn → agent tự dùng fallback của vai trò)") {
            ForEach(Provider.allCases) { p in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(p.title).bold()
                        if o.team.limitedProviders.contains(p) {
                            Button("Bỏ đánh dấu limit") { o.clearLimit(p) }
                            .tint(.orange)
                        }
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

    var template: some View {
        Section("Mẫu team (dùng cho mọi dự án mới; từng dự án vẫn sửa riêng được)") {
            HStack {
                Button("Lưu team này làm mẫu mặc định") {
                    do {
                        try o.team.saveAsTemplate()
                        templateNote = "Đã lưu. Dự án mới sẽ dùng team này."
                    } catch {
                        templateNote = "Không lưu được: \(error.localizedDescription)"
                    }
                }
                Button("Áp dụng mẫu cho dự án này") {
                    o.applyTemplate()
                    templateNote = "Đã áp dụng mẫu."
                }
                .disabled(!o.chats.isEmpty)
                .help(o.chats.isEmpty ? "Thay vai trò và vị trí bằng mẫu mặc định." : "Dự án đã có chat; xoá các chat trước để không chat nào mất agent.")
                Spacer()
                Text(templateNote).font(.caption).foregroundStyle(.secondary)
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
        }
    }
}
