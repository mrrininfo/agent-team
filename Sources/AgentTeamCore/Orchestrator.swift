import Foundation
import Observation

/// Runs one provider turn, streaming events; returns an error description when the process failed.
public typealias TurnRunner = @MainActor (_ chatId: String, _ request: TurnRequest, _ cwd: URL,
                                          _ onEvent: @escaping @MainActor (RunEvent) -> Void) async -> String?

@MainActor @Observable
public final class Orchestrator {
    public let paths: TeamPaths
    public var team: Team { didSet { saveTeam() } }
    public private(set) var chats: [Chat] = []
    /// Provider rawValue → latest known subscription limits (account-wide, shared via Quota.file).
    public private(set) var quotas: [String: ProviderQuota] = Quota.load()

    @ObservationIgnored public var runner: TurnRunner
    @ObservationIgnored public var cancelTurn: (String) -> Void = { _ in }
    @ObservationIgnored public var gitStatus: (URL) -> String? = Orchestrator.defaultGitStatus
    @ObservationIgnored var dispatchCount: [String: Int] = [:]
    @ObservationIgnored var stopping: Set<String> = []
    @ObservationIgnored var timer: Timer?
    @ObservationIgnored var ticks = 0
    /// Path of the `agy` binary, if installed (set by the app); used only to read Antigravity's quota panel.
    @ObservationIgnored public var antigravityBinary: () -> String? = { nil }
    /// One probe at a time across all windows: each run drives agy's TUI for ~20 s.
    static var antigravityProbeRunning = false
    /// Set when the workspace is closed or switched away from: nothing new starts, running turns are requeued.
    @ObservationIgnored public private(set) var suspended = false

    public init(workspace: URL, runner: @escaping TurnRunner) throws {
        paths = TeamPaths(workspace: workspace)
        try paths.ensure()
        if let data = try? Data(contentsOf: paths.teamFile) {
            if let t = try? jsonDecoder.decode(Team.self, from: data) {
                team = t
            } else {
                // Unreadable (e.g. older schema): keep the user's file instead of silently overwriting it.
                try? data.write(to: paths.teamFile.appendingPathExtension("bak-\(Int(Date().timeIntervalSince1970))"))
                team = Team.template()
            }
        } else {
            team = Team.template()
        }
        self.runner = runner
        saveTeam()
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.chats, includingPropertiesForKeys: nil)) ?? []
        chats = files.compactMap { try? jsonDecoder.decode(Chat.self, from: Data(contentsOf: $0)) }
            .sorted { ($0.messages.first?.date ?? .distantPast) < ($1.messages.first?.date ?? .distantPast) }
        // Crash/quit recovery: stop provider processes orphaned by the previous run, then queue unfinished work again.
        ProcessRunner.stopOrphans(paths)
        for c in chats where c.status == .running || c.status == .queued {
            update(c.id) { $0.pending = $0.inFlight + $0.pending; $0.inFlight = []; $0.status = $0.pending.isEmpty ? .idle : .queued }
        }
    }

    // MARK: - Lookup

    public func chat(_ id: String) -> Chat? { chats.first { $0.id == id } }
    public func chats(of agentId: String) -> [Chat] { chats.filter { $0.agentId == agentId } }
    public var runningCount: Int { chats.filter { $0.status == .running }.count }

    func update(_ id: String, _ f: (inout Chat) -> Void) {
        guard let i = chats.firstIndex(where: { $0.id == id }) else { return }
        f(&chats[i])
        try? jsonEncoder.encode(chats[i]).write(to: paths.chatFile(id), options: .atomic)
    }

    func saveTeam() {
        try? jsonEncoder.encode(team).write(to: paths.teamFile, options: .atomic)
        try? team.roster().write(to: paths.rosterFile, atomically: true, encoding: .utf8)
    }

    // MARK: - User actions

    @discardableResult
    public func newChat(agentId: String, title: String, replyTo: String? = nil) -> String {
        let c = Chat(agentId: agentId, title: title, replyTo: replyTo)
        chats.append(c)
        update(c.id) { _ in }
        return c.id
    }

    public func send(_ text: String, to chatId: String) {
        update(chatId) { $0.autoTurns = 0 }
        enqueue(chatId, text, kind: .user)
    }

    public func rename(_ chatId: String, _ title: String) { update(chatId) { $0.title = title } }

    public var totalTokens: Int { chats.reduce(0) { $0 + $1.tokens } }

    public func clearLimit(_ p: Provider) {
        team.limitedProviders.remove(p)
        team.limitedSince[p.rawValue] = nil
        retryLimited()
    }

    /// Limits reset on their own (Claude/Codex windows); retry a provider after the cooldown so work continues unattended.
    public func releaseExpiredLimits(now: Date = Date()) {
        let cooldown = TimeInterval(team.limitCooldownMinutes * 60)
        for p in team.limitedProviders where (team.limitedSince[p.rawValue] ?? .distantPast).addingTimeInterval(cooldown) <= now {
            clearLimit(p)
        }
    }

    /// After a provider comes back, chats parked as `limited` run again.
    public func retryLimited() {
        for c in chats where c.status == .limited && !c.pending.isEmpty { update(c.id) { $0.status = .queued } }
        pump()
    }

    public func deleteChat(_ id: String) {
        stop(id)
        chats.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: paths.chatFile(id))
    }

    public func stop(_ chatId: String) {
        guard chat(chatId)?.status == .running else {
            update(chatId) { if $0.status == .queued { $0.status = .idle } }
            return
        }
        stopping.insert(chatId)
        cancelTurn(chatId)
    }

    /// Moves unfinished work of `from` into chat `to` (usually a fresh chat of the same role on another provider).
    public func transfer(from: String, to: String, reason: String = "chuyển giao thủ công") {
        guard let s = chat(from), from != to else { return }
        let pkg = Handoff.package(chat: s, role: team.agent(s.agentId).flatMap { team.role($0.roleId) }, reason: reason,
                                  inputs: s.inFlight + s.pending, notes: notes(from), gitStatus: gitStatus(paths.workspace))
        if s.status == .running { stop(from) }
        update(from) {
            $0.pending = []
            $0.inFlight = []
            $0.status = .done
            $0.messages.append(Message(.system, "Đã chuyển việc sang chat \(to)."))
        }
        update(to) { $0.replyTo = s.replyTo ?? $0.replyTo }
        update(from) { $0.replyTo = nil }
        enqueue(to, pkg, kind: .handoff)
    }

    /// Replaces roles and agents with the template. Only while no chat exists, so no chat loses its agent.
    public func applyTemplate() {
        guard chats.isEmpty else { return }
        let t = Team.template()
        team.roles = t.roles
        team.agents = t.agents
    }

    /// One-click migration, e.g. when a subscription ends: every agent on `provider` moves to `profile`.
    public func replaceProvider(_ provider: Provider, with profile: Profile) {
        for i in team.agents.indices where team.agents[i].profile.provider == provider { team.agents[i].profile = profile }
    }

    func notes(_ chatId: String) -> String? { try? String(contentsOf: paths.noteFile(chatId), encoding: .utf8) }

    // MARK: - Queue

    func enqueue(_ chatId: String, _ text: String, kind: Message.Kind) {
        update(chatId) {
            $0.messages.append(Message(kind, text))
            $0.pending.append(Input(text: text, fromUser: kind == .user))
            if $0.status != .running { $0.status = .queued }
        }
        pump()
    }

    /// Pauses this workspace without losing work: running turns are cancelled and their inputs queued again,
    /// so reopening the workspace resumes them.
    public func suspend() {
        suspended = true
        stopInboxPolling()
        for c in chats where c.status == .running { cancelTurn(c.id) }
    }

    public func pump() {
        guard !suspended else { return }
        while runningCount < team.maxConcurrent, let next = chats.first(where: { $0.status == .queued }) {
            update(next.id) { $0.status = .running }
            Task { await runTurn(next.id) }
        }
    }

    /// Each debate round costs the Lead two callback turns, so the loop guard never cuts a debate the user configured.
    var autoTurnCap: Int { max(team.maxAutoTurns, (team.debateRounds ?? 2) * 2 + 6) }

    func preamble(_ chat: Chat, _ agent: Agent, _ role: Role) -> String {
        var s = """
        # AGENT TEAM — HỢP ĐỒNG VAI TRÒ
        Bạn là \(role.name) (agent \(agent.id), chat \(chat.id)) trong một team AI. Workspace: \(paths.workspace.path)
        Quyền: \(role.access.title).\(role.access == .readOnly ? " Không sửa file của dự án." : "")

        \(role.contract)
        """
        if role.canDispatch {
            s += """


            ## Team
            \(team.roster())

            ## Giao việc
            - Giao việc mới: chạy lệnh shell `agentteam dispatch --from \(chat.id) --to <agentId|role> --new-task "<tiêu đề>" "<nội dung>"`.
            - Tiếp tục chat cũ của agent: thay `--new-task "<tiêu đề>"` bằng `--tab <chatId>`.
            - Chỉ viết "sẽ giao" KHÔNG tạo nhiệm vụ; phải chạy lệnh. Mỗi lượt tối đa \(team.maxDispatchPerTurn) lần giao.
            - Nội dung giao phải tự đủ: phạm vi, đầu ra, bằng chứng cần báo cáo (agent nhận không thấy cuộc trò chuyện này).
            - ACK `queued/started` chỉ là đã xếp hàng. Giao xong thì kết thúc lượt; kết quả tự gửi về chat này.
            - Xem đầy đủ một kết quả bị cắt: `agentteam show <chatId>`.

            ## Thảo luận
            - Số vòng phản biện planner ↔ critic tối đa: \(team.debateRounds ?? 2) (con số này thay cho số vòng ghi trong hợp đồng; người dùng ghi số khác thì theo người dùng).
            """
        }
        s += """


        ## Báo cáo
        - Câu trả lời cuối của mỗi lượt được chuyển nguyên văn cho người giao việc: ngắn gọn, có bằng chứng (file:line, lệnh đã chạy, kết quả).
        - Việc dài: ghi tiến độ ngắn vào `.agentteam/notes/\(chat.id).md` (nếu được ghi) để có thể bàn giao khi bị ngắt.

        ---

        """
        return s
    }

    func runTurn(_ chatId: String) async {
        guard let c = chat(chatId), let agent = team.agent(c.agentId), let role = team.role(agent.roleId) else {
            update(chatId) { $0.status = .failed; $0.messages.append(Message(.system, "Agent hoặc vai trò không còn tồn tại.")) }
            return pump()
        }
        guard let profile = team.effectiveProfile(for: agent) else {
            update(chatId) { $0.status = .limited; $0.messages.append(Message(.system, "Không còn provider khả dụng cho agent này (đã tắt hoặc bị limit). Bật lại provider hoặc chuyển việc.")) }
            return pump()
        }
        let inputs = c.pending
        if !inputs.contains(where: \.fromUser) {
            if c.autoTurns >= autoTurnCap {
                update(chatId) { $0.status = .idle; $0.messages.append(Message(.system, "Tạm dừng sau \(autoTurnCap) lượt tự động liên tiếp (chống vòng lặp tốn token). Gửi tin nhắn để tiếp tục.")) }
                return pump()
            }
        }
        let resumable = c.sessionId != nil && c.sessionProfile == profile
        var body = inputs.map(\.text).joined(separator: "\n\n---\n\n")
        if !resumable && c.messages.contains(where: { $0.kind == .assistant }) {
            body = Handoff.package(chat: c, role: role, reason: "tiếp tục trên \(profile.label)",
                                   inputs: inputs, notes: notes(chatId), gitStatus: gitStatus(paths.workspace))
        }
        let prompt = (resumable ? "" : preamble(c, agent, role)) + body
        update(chatId) {
            if !inputs.contains(where: \.fromUser) { $0.autoTurns += 1 }
            $0.pending = []
            $0.inFlight = inputs
            $0.activity = "Đang chạy trên \(profile.label)…"
            $0.runningProfile = profile
            if !resumable { $0.sessionId = nil }
        }
        dispatchCount[chatId] = 0

        var final: String?
        var failure: String?
        let req = TurnRequest(prompt: prompt, profile: profile, sessionId: resumable ? c.sessionId : nil, access: role.access)
        let exitError = await runner(chatId, req, paths.workspace) { [weak self] e in
            switch e {
            case .session(let s):
                self?.update(chatId) { $0.sessionId = s; $0.sessionProfile = profile }
            case .progress(let t):
                let line = String(t.replacingOccurrences(of: "\n", with: " ").prefix(200))
                self?.update(chatId) { $0.activity = line; $0.trail = Array(($0.trail + [line]).suffix(30)) }
            case .usage(let n): self?.update(chatId) { $0.tokens += max(0, n) }
            case .quota(let w):
                self?.quotas[profile.provider.rawValue] = ProviderQuota(windows: w, updated: Date())
                if let q = self?.quotas { Quota.save(q) }
            case .final(let t): final = t
            case .failure(let t): failure = t
            }
        }
        finish(chatId, inputs: inputs, final: final, error: failure ?? exitError, profile: profile)
        if profile.provider == .codex { refreshQuotas() }
    }

    func finish(_ chatId: String, inputs: [Input], final: String?, error: String?, profile: Profile) {
        let wasStopped = stopping.remove(chatId) != nil
        update(chatId) { $0.activity = ""; $0.runningProfile = nil }
        if suspended && final == nil {
            update(chatId) { $0.pending = inputs + $0.pending; $0.inFlight = []; $0.status = .queued }
            return
        }
        if wasStopped {
            update(chatId) { $0.inFlight = []; $0.status = $0.pending.isEmpty ? .idle : .queued; $0.messages.append(Message(.system, "Đã dừng.")) }
            return pump()
        }
        guard let c = chat(chatId) else { return pump() }
        let delegated = inputs.contains { !$0.fromUser }

        if let final {
            update(chatId) {
                $0.messages.append(Message(.assistant, final.isEmpty ? "(không có nội dung trả lời)" : final))
                $0.inFlight = []
                $0.status = $0.pending.isEmpty ? .done : .queued
            }
            if delegated { callback(from: c, status: "xong", text: final) }
        } else if let error, isLimitError(error) {
            team.limitedProviders.insert(profile.provider)
            team.limitedSince[profile.provider.rawValue] = Date()
            let canContinue = team.autoFailover && team.agent(c.agentId).flatMap(team.effectiveProfile) != nil
            update(chatId) {
                $0.pending = $0.inFlight + $0.pending
                $0.inFlight = []
                $0.status = canContinue ? .queued : .limited
                $0.messages.append(Message(.system, "\(profile.provider.title) bị limit: \(clip(error, 300))\n"
                    + (canContinue ? "Tự động chuyển sang provider dự phòng kèm gói bàn giao." : "Bật provider khác, thêm fallback cho vai trò, hoặc dùng Chuyển việc.")))
            }
        } else {
            let msg = error ?? "Không nhận được kết quả từ \(profile.provider.binaryName)."
            update(chatId) {
                $0.inFlight = []
                $0.status = $0.pending.isEmpty ? .failed : .queued
                $0.messages.append(Message(.system, "Lỗi: \(clip(msg, 1500))"))
            }
            if delegated { callback(from: c, status: "lỗi", text: msg) }
        }
        pump()
    }

    func callback(from c: Chat, status: String, text: String) {
        guard let target = c.replyTo, chat(target) != nil else { return }
        let role = team.agent(c.agentId).flatMap { team.role($0.roleId) }?.name ?? "agent"
        var body = "[Kết quả từ \(role) \(c.agentId) · chat \(c.id) · \"\(c.title)\" · \(status)]\n" + String(text.prefix(team.callbackLimit))
        if text.count > team.callbackLimit { body += "\n…[đã cắt; xem đủ: agentteam show \(c.id)]" }
        enqueue(target, body, kind: .callback)
    }

    // MARK: - Inbox

    public func startInboxPolling() {
        timer?.invalidate()
        refreshQuotas()
        // shortcut: 1s polling instead of FSEvents; fine for a handful of agents.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.processInbox()
                self?.releaseExpiredLimits()
                guard let self else { return }
                self.ticks += 1
                if self.ticks % 60 == 0 { self.refreshQuotas() }
            }
        }
    }

    public func stopInboxPolling() { timer?.invalidate() }

    /// Re-reads limits: Claude's from the shared file (other windows may have updated it), Codex's from its session files.
    public func refreshQuotas(force: Bool = false) {
        var q = Quota.load()
        if let c = Quota.readCodex() { q[Provider.codex.rawValue] = c }
        quotas = q
        Quota.save(q)
        refreshAntigravityQuota(force: force)
    }

    /// Antigravity's quota costs no tokens but ~20 s of a background agy session, so at most every 10 minutes.
    func refreshAntigravityQuota(force: Bool) {
        let key = Provider.antigravity.rawValue
        let stale = Date().timeIntervalSince(quotas[key]?.updated ?? .distantPast) > 600
        guard (force || stale), !Self.antigravityProbeRunning, !team.disabledProviders.contains(.antigravity),
              let bin = antigravityBinary() else { return }
        Self.antigravityProbeRunning = true
        let dir = Quota.file.deletingLastPathComponent().appendingPathComponent("agy-usage")
        Task.detached {
            let windows = Quota.probeAntigravity(binary: bin, workDir: dir).map { Quota.parseAntigravity($0) } ?? []
            await MainActor.run {
                Self.antigravityProbeRunning = false
                guard !windows.isEmpty else { return }
                var q = Quota.load()
                q[key] = ProviderQuota(windows: windows, updated: Date())
                Quota.save(q)
                self.quotas = q
            }
        }
    }

    public func processInbox() {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.inbox, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f) else { continue }
            try? FileManager.default.removeItem(at: f)
            let ack: DispatchAck
            if let r = try? jsonDecoder.decode(DispatchRequest.self, from: data) {
                ack = handle(r)
            } else {
                ack = DispatchAck(id: f.deletingPathExtension().lastPathComponent, disposition: "rejected", reason: "Yêu cầu không đọc được.")
            }
            try? jsonEncoder.encode(ack).write(to: paths.ackFile(ack.id), options: .atomic)
        }
    }

    public func handle(_ r: DispatchRequest) -> DispatchAck {
        func reject(_ why: String) -> DispatchAck { DispatchAck(id: r.id, disposition: "rejected", reason: why) }
        guard let from = chat(r.from), let fromAgent = team.agent(from.agentId) else { return reject("Chat gửi \(r.from) không tồn tại.") }
        guard team.role(fromAgent.roleId)?.canDispatch == true else { return reject("Vai trò của chat gửi không được phép giao việc.") }
        guard dispatchCount[r.from, default: 0] < team.maxDispatchPerTurn else { return reject("Vượt quá \(team.maxDispatchPerTurn) lần giao trong một lượt.") }
        guard let agent = team.agent(r.to) ?? team.agents.first(where: { $0.roleId == r.to }) else {
            return reject("Không có agent/vai trò '\(r.to)'. Xem: agentteam agents")
        }
        guard !r.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return reject("Nội dung giao việc trống.") }
        let target: String
        if let tab = r.tab {
            guard let t = chat(tab), t.agentId == agent.id, tab != r.from else { return reject("Chat \(tab) không thuộc agent \(agent.id).") }
            target = t.id
        } else {
            target = newChat(agentId: agent.id, title: r.title ?? "Nhiệm vụ")
        }
        dispatchCount[r.from, default: 0] += 1
        update(target) { $0.replyTo = r.from }
        let fromRole = team.role(fromAgent.roleId)?.name ?? fromAgent.roleId
        enqueue(target, "[Giao việc từ \(fromRole) \(fromAgent.id) · handoff \(r.id)]\n" + r.body, kind: .task)
        return DispatchAck(id: r.id, disposition: chat(target)?.status == .running ? "started" : "queued", chatId: target)
    }

    nonisolated public static func defaultGitStatus(_ dir: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path, "status", "--porcelain"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
