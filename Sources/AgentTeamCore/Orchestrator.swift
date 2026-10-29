import CryptoKit
import Darwin
import Foundation
import Observation

/// Runs one provider turn, streaming events; returns an error description when the process failed.
public typealias TurnRunner = @MainActor (_ chatId: String, _ request: TurnRequest, _ cwd: URL,
                                          _ onEvent: @escaping @MainActor (RunEvent) -> Void) async -> String?

public enum OrchestratorError: LocalizedError, Sendable {
    case workspaceLocked(String)

    public var errorDescription: String? {
        switch self {
        case .workspaceLocked(let path):
            return "Thư mục dự án đang được mở bởi một tiến trình khác (lock bận: \(path))."
        }
    }
}

public struct HealthRecord: Codable, Sendable {
    public var pid: Int32
    public var gitSHA: String
    public var loadedChats: Int
    public var failedChatFiles: Int
    public var chatHashes: [String: String]
    public var time: Date

    public init(pid: Int32, gitSHA: String, loadedChats: Int, failedChatFiles: Int, chatHashes: [String: String], time: Date = Date()) {
        self.pid = pid
        self.gitSHA = gitSHA
        self.loadedChats = loadedChats
        self.failedChatFiles = failedChatFiles
        self.chatHashes = chatHashes
        self.time = time
    }
}

@MainActor @Observable
public final class Orchestrator {
    public let paths: TeamPaths
    public var team: Team { didSet { saveTeam() } }
    public private(set) var chats: [Chat] = []
    /// Provider rawValue → latest known subscription limits (account-wide, shared via Quota.file).
    public private(set) var quotas: [String: ProviderQuota] = Quota.load()
    public private(set) var failedChatFiles: [String] = []
    public private(set) var loadErrors: [String] = []
    public private(set) var lastIOError: String?

    @ObservationIgnored private nonisolated(unsafe) var lockFd: Int32 = -1
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
    public static var antigravityProbeRunning = false
    @ObservationIgnored var agyLastAttempt: Date?
    @ObservationIgnored public var agyFailCount: Int = 0
    @ObservationIgnored public private(set) var agyProbeError: (message: String, at: Date)?
    /// Set when the workspace is closed or switched away from: nothing new starts, running turns are requeued.
    @ObservationIgnored public private(set) var suspended = false
    /// When true, orchestrator is in install-check mode: writes health.json but keeps pump, polling and probe disabled.
    @ObservationIgnored public var isInstallCheck: Bool = false
    @ObservationIgnored private var cachedGitSHA: String = ""

    public var agyBackoffMinutes: Int {
        let mins = [10, 20, 40, 60]
        return mins[min(max(0, agyFailCount - 1), mins.count - 1)]
    }

    public func clearLastIOError() {
        lastIOError = nil
    }

    private static func acquireLock(paths: TeamPaths) throws -> Int32 {
        try paths.ensureLockDirectory()
        let fd = open(paths.lockFile.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            throw OrchestratorError.workspaceLocked(paths.workspace.path)
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            throw OrchestratorError.workspaceLocked(paths.workspace.path)
        }
        return fd
    }

    nonisolated public func releaseLock() {
        if lockFd >= 0 {
            flock(lockFd, LOCK_UN)
            close(lockFd)
            lockFd = -1
        }
    }

    deinit {
        releaseLock()
    }

    public init(workspace: URL, isInstallCheck: Bool = (ProcessInfo.processInfo.environment["AGENTTEAM_INSTALL_CHECK"] == "1"),
                runner: @escaping TurnRunner) throws {
        self.isInstallCheck = isInstallCheck
        paths = TeamPaths(workspace: workspace)
        // Must acquire inter-process lock BEFORE paths.ensure() or any writes/kills/requeues
        lockFd = try Self.acquireLock(paths: paths)
        if !isInstallCheck {
            try paths.ensure()
        }

        if let data = try? Data(contentsOf: paths.teamFile) {
            if let t = try? jsonDecoder.decode(Team.self, from: data) {
                team = t
            } else {
                // Unreadable (e.g. older schema): keep the user's file instead of silently overwriting it.
                if !isInstallCheck {
                    try? data.write(to: paths.teamFile.appendingPathExtension("bak-\(Int(Date().timeIntervalSince1970))"))
                }
                team = Team.template()
            }
        } else {
            team = Team.template()
        }
        self.runner = runner
        if !isInstallCheck {
            saveTeam()
        }

        var loaded: [Chat] = []
        var failedFiles: [String] = []
        var errors: [String] = []
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.chats, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                let chat = try jsonDecoder.decode(Chat.self, from: data)
                loaded.append(chat)
            } catch {
                failedFiles.append(file.lastPathComponent)
                errors.append("Không đọc được \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        chats = loaded.sorted { ($0.messages.first?.date ?? .distantPast) < ($1.messages.first?.date ?? .distantPast) }
        failedChatFiles = failedFiles
        loadErrors = errors

        if !isInstallCheck {
            // Crash/quit recovery: stop provider processes orphaned by previous run.
            // Legacy schema or unverified ownership processes are blocked from auto-resume.
            let cleanup = ProcessRunner.stopOrphans(paths)
            for c in chats where c.status == .running || c.status == .queued {
                if cleanup.legacyChatIds.contains(c.id) {
                    update(c.id) {
                        $0.status = .failed
                        $0.messages.append(Message(.system, "Cảnh báo: Tiến trình trước đó lưu theo schema cũ (chỉ có PID, thiếu startTime và đường dẫn nhị phân). Chặn tự động chạy lại để tránh xung đột."))
                    }
                } else if cleanup.unverifiableChatIds.contains(c.id) {
                    update(c.id) {
                        $0.status = .failed
                        $0.messages.append(Message(.system, "Cảnh báo: Không thể xác minh quyền sở hữu tiến trình trước đó (có thể do CLI chạy qua script/interpreter như node/python). Tiến trình không bị tắt tự động để bảo đảm an toàn; chặn tự động chạy lại để tránh xung đột. Vui lòng kiểm tra và tắt tiến trình thủ công nếu cần."))
                    }
                } else {
                    update(c.id) {
                        $0.pending = $0.inFlight + $0.pending
                        $0.inFlight = []
                        $0.status = $0.pending.isEmpty ? .idle : .queued
                    }
                }
            }
        }

        let envSHA = ProcessInfo.processInfo.environment["AGENTTEAM_GIT_SHA"]
        if let envSHA, !envSHA.isEmpty {
            cachedGitSHA = envSHA
        } else {
            cachedGitSHA = Self.readGitCommitSHA(workspace) ?? ""
        }

        recordHealth()
    }

    public func recordHealth() {
        var hashes: [String: String] = [:]
        for c in chats {
            let combined = (c.messages.map(\.text) + c.pending.map(\.text) + c.inFlight.map(\.text)).joined()
            hashes[c.id] = SHA256.hash(data: Data(combined.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let rec = HealthRecord(
            pid: ProcessInfo.processInfo.processIdentifier,
            gitSHA: currentGitSHA(),
            loadedChats: chats.count,
            failedChatFiles: failedChatFiles.count,
            chatHashes: hashes,
            time: Date()
        )
        try? jsonEncoder.encode(rec).write(to: paths.healthFile, options: .atomic)
    }

    private func currentGitSHA() -> String {
        if let envSHA = ProcessInfo.processInfo.environment["AGENTTEAM_GIT_SHA"], !envSHA.isEmpty {
            return envSHA
        }
        return cachedGitSHA
    }

    private static func readGitCommitSHA(_ dir: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path, "rev-parse", "HEAD"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    // MARK: - Lookup

    public func chat(_ id: String) -> Chat? { chats.first { $0.id == id } }
    public func chats(of agentId: String) -> [Chat] { chats.filter { $0.agentId == agentId } }
    public var runningCount: Int { chats.filter { $0.status == .running }.count }

    func update(_ id: String, _ f: (inout Chat) -> Void) {
        guard let i = chats.firstIndex(where: { $0.id == id }) else { return }
        f(&chats[i])
        do {
            try jsonEncoder.encode(chats[i]).write(to: paths.chatFile(id), options: .atomic)
        } catch {
            lastIOError = "Lỗi lưu chat \(id): \(error.localizedDescription)"
        }
    }

    func saveTeam() {
        try? jsonEncoder.encode(team).write(to: paths.teamFile, options: .atomic)
        try? team.roster().write(to: paths.rosterFile, atomically: true, encoding: .utf8)
    }

    // MARK: - User actions

    @discardableResult
    public func newChat(agentId: String, title: String, replyTo: String? = nil) -> String {
        let c = Chat(id: shortId(), agentId: agentId, title: title, replyTo: replyTo)
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

    /// Limits reset on their own (Claude/Codex windows); retry a provider after cooldown so work continues unattended.
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

    /// Moves unfinished work of `from` into chat `to` (usually a fresh chat of same role on another provider).
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

    /// Replaces roles and agents with template. Only while no chat exists, so no chat loses its agent.
    public func applyTemplate() {
        guard chats.isEmpty else { return }
        let t = Team.template()
        team.roles = t.roles
        team.agents = t.agents
    }

    /// One-click migration: every agent on `provider` moves to `profile`.
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
        if runningCount == 0 {
            releaseLock()
        }
    }

    public func pump() {
        guard !suspended, !isInstallCheck else { return }
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

        // R5: Only resume when (profile, access, canDispatch) all match strictly; nil defaults to not resumable
        let resumable = c.sessionId != nil
            && c.sessionProfile == profile
            && c.sessionAccess == role.access
            && c.sessionCanDispatch == role.canDispatch

        var body = inputs.map(\.text).joined(separator: "\n\n---\n\n")
        // R1: Hand off full context even if the first turn failed on limit
        if !resumable && (c.messages.contains(where: { $0.kind == .assistant || $0.kind == .system }) || c.sessionId != nil) {
            body = Handoff.package(chat: c, role: role, reason: "tiếp tục trên \(profile.label)",
                                   inputs: inputs, notes: notes(chatId), gitStatus: gitStatus(paths.workspace))
        }
        let prompt = (resumable ? "" : preamble(c, agent, role)) + body

        // R1: Validate argv size before setting inFlight. If exceeded, keep in pending and report error.
        if profile.provider == .antigravity && prompt.utf8.count > Provider.maxAntigravityPromptBytes {
            update(chatId) {
                $0.status = .failed
                $0.messages.append(Message(.system, "Lỗi: Prompt vượt ngưỡng argv của Antigravity (\(prompt.utf8.count) bytes > \(Provider.maxAntigravityPromptBytes)). Giữ nguyên pending; hãy rút gọn prompt hoặc chuyển sang provider hỗ trợ stdin (Claude/Codex)."))
            }
            return pump()
        }

        update(chatId) {
            if !inputs.contains(where: \.fromUser) { $0.autoTurns += 1 }
            $0.pending = []
            $0.inFlight = inputs
            $0.activity = "Đang chạy trên \(profile.label)…"
            $0.runningProfile = profile
            if !resumable {
                $0.sessionId = nil
                $0.reportedModel = nil
                $0.reportedModelProvider = nil
            }
        }
        dispatchCount[chatId] = 0

        var final: String?
        var failure: String?
        var turnReportedModel: String?
        let req = TurnRequest(prompt: prompt, profile: profile, sessionId: resumable ? c.sessionId : nil,
                              access: role.access, canDispatch: role.canDispatch)
        let exitError = await runner(chatId, req, paths.workspace) { [weak self] e in
            switch e {
            case .session(let s):
                self?.update(chatId) {
                    $0.sessionId = s
                    $0.sessionProfile = profile
                    $0.sessionAccess = role.access
                    $0.sessionCanDispatch = role.canDispatch
                }
            case .progress(let t):
                let line = String(t.replacingOccurrences(of: "\n", with: " ").prefix(200))
                self?.update(chatId) { $0.activity = line; $0.trail = Array(($0.trail + [line]).suffix(30)) }
            case .usage(let n): self?.update(chatId) { $0.tokens += max(0, n) }
            case .quota(let w):
                self?.quotas[profile.provider.rawValue] = ProviderQuota(windows: w, updated: Date())
                if let q = self?.quotas { Quota.save(q) }
            case .modelMetadata(let m):
                turnReportedModel = m
                self?.update(chatId) {
                    $0.reportedModel = m
                    $0.reportedModelProvider = profile.provider.rawValue
                }
            case .final(let t): final = t
            case .failure(let t): failure = t
            }
        }
        finish(chatId, inputs: inputs, final: final, error: failure ?? exitError, profile: profile, turnReportedModel: turnReportedModel)
        if profile.provider == .codex { refreshQuotas() }
    }

    func finish(_ chatId: String, inputs: [Input], final: String?, error: String?, profile: Profile, turnReportedModel: String? = nil) {
        defer {
            if suspended && runningCount == 0 {
                releaseLock()
            }
        }
        let wasStopped = stopping.remove(chatId) != nil
        update(chatId) { $0.activity = ""; $0.runningProfile = nil }
        if suspended && final == nil {
            update(chatId) { $0.pending = inputs + $0.pending; $0.inFlight = []; $0.status = .queued }
            recordHealth()
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
            if delegated { callback(from: c, status: "xong", text: final, turnProfile: profile, turnModel: turnReportedModel) }
        } else if let error, isLimitError(error) {
            team.limitedProviders.insert(profile.provider)
            team.limitedSince[profile.provider.rawValue] = Date()
            let canContinue = team.autoFailover && team.agent(c.agentId).flatMap(team.effectiveProfile) != nil
            update(chatId) {
                $0.pending = $0.inFlight + $0.pending
                $0.inFlight = []
                $0.status = canContinue ? .queued : .limited
                $0.reportedModel = nil
                $0.reportedModelProvider = nil
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
            if delegated { callback(from: c, status: "lỗi", text: msg, turnProfile: profile, turnModel: turnReportedModel) }
        }
        recordHealth()
        pump()
    }

    func callback(from c: Chat, status: String, text: String, turnProfile: Profile? = nil, turnModel: String? = nil) {
        guard let target = c.replyTo, chat(target) != nil else { return }
        let role = team.agent(c.agentId).flatMap { team.role($0.roleId) }?.name ?? "agent"
        let effective = turnProfile ?? c.runningProfile ?? team.agent(c.agentId).flatMap(team.effectiveProfile)
        let providerTitle = effective?.provider.title ?? "Provider"
        let rep = turnModel
        let modelDesc: String
        if let rep {
            modelDesc = "\(rep) (đã xác minh)"
        } else {
            let cfg = effective?.model ?? "mặc định"
            modelDesc = "\(cfg) (cấu hình)"
        }
        var body = "[Kết quả từ \(role) \(c.agentId) · chat \(c.id) · profile: \(providerTitle) · \(modelDesc) · \"\(c.title)\" · \(status)]\n" + String(text.prefix(team.callbackLimit))
        if text.count > team.callbackLimit { body += "\n…[đã cắt; xem đủ: agentteam show \(c.id)]" }
        enqueue(target, body, kind: .callback)
    }

    // MARK: - Inbox & Dispatch

    public func startInboxPolling() {
        guard !isInstallCheck else { return }
        timer?.invalidate()
        refreshQuotas()
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

    public func refreshQuotas(force: Bool = false) {
        guard !isInstallCheck else { return }
        var q = Quota.load()
        if let c = Quota.readCodex() { q[Provider.codex.rawValue] = c }
        quotas = q
        Quota.save(q)
        refreshAntigravityQuota(force: force)
    }

    public func refreshAntigravityQuota(force: Bool) {
        guard !isInstallCheck else { return }
        let key = Provider.antigravity.rawValue
        guard !Self.antigravityProbeRunning else { return }
        guard !team.disabledProviders.contains(.antigravity) else { return }
        guard let bin = antigravityBinary(), FileManager.default.isExecutableFile(atPath: bin) else { return }

        let now = Date()
        let interval = TimeInterval(agyBackoffMinutes * 60)
        let stale = now.timeIntervalSince(agyLastAttempt ?? .distantPast) >= interval
        guard force || stale else { return }

        Self.antigravityProbeRunning = true
        agyLastAttempt = now
        let dir = Quota.workDir
        Task.detached {
            let output = Quota.probeAntigravity(binary: bin, workDir: dir)
            let windows = output.map { Quota.parseAntigravity($0) } ?? []
            await MainActor.run {
                Self.antigravityProbeRunning = false
                if windows.isEmpty {
                    self.agyFailCount += 1
                    self.agyProbeError = ("Không đọc được dữ liệu quota từ agy (thử lại sau \(self.agyBackoffMinutes) phút)", Date())
                } else {
                    self.agyFailCount = 0
                    self.agyProbeError = nil
                    var q = Quota.load()
                    q[key] = ProviderQuota(windows: windows, updated: Date())
                    Quota.save(q)
                    self.quotas = q
                }
            }
        }
    }

    public func quotaStatus(for provider: Provider) -> QuotaStatus {
        if team.disabledProviders.contains(provider) {
            return .disabled
        }
        if provider == .antigravity {
            let bin = antigravityBinary()
            if bin == nil || !FileManager.default.isExecutableFile(atPath: bin!) {
                return .noBinary
            }
            if Self.antigravityProbeRunning {
                return .reading
            }
            if let err = agyProbeError {
                return .error(message: err.message, at: err.at)
            }
            if let q = quotas[provider.rawValue] {
                return .available(q)
            }
            return .reading
        } else {
            let bin = ProcessRunner(helperDir: nil).binary(for: provider, override: team.binaryPaths[provider.rawValue])
            if bin == nil {
                return .noBinary
            }
            if let q = quotas[provider.rawValue] {
                return .available(q)
            }
            return .reading
        }
    }

    /// Write-once: an ACK on disk is never replaced. Single writer under the D2 lock.
    func persistAck(_ ack: DispatchAck) throws {
        let url = paths.ackFile(ack.id)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try jsonEncoder.encode(ack).write(to: url, options: .atomic)
    }

    public func processInbox() {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.inbox, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f) else { continue }
            let reqId = f.deletingPathExtension().lastPathComponent
            if let r = try? jsonDecoder.decode(DispatchRequest.self, from: data) {
                _ = handle(r)
                // handle() is the only ACK writer; no ACK on disk means a transient error, so retry next tick.
                if FileManager.default.fileExists(atPath: paths.ackFile(r.id).path) {
                    try? FileManager.default.removeItem(at: f)
                }
            } else {
                let ack = DispatchAck(id: reqId, disposition: "rejected", reason: "Yêu cầu không đọc được.")
                do {
                    try persistAck(ack)
                    try? FileManager.default.removeItem(at: f)
                } catch {
                    lastIOError = "Lỗi ghi ACK \(ack.id): \(error.localizedDescription)"
                }
            }
        }
    }

    public func handle(_ r: DispatchRequest) -> DispatchAck {
        let fp = r.fingerprint
        func reject(_ why: String, persist: Bool = true) -> DispatchAck {
            let ack = DispatchAck(id: r.id, disposition: "rejected", chatId: nil, reason: why, fingerprint: fp)
            if persist {
                do {
                    try persistAck(ack)
                } catch {
                    lastIOError = "Lỗi ghi ACK \(ack.id): \(error.localizedDescription)"
                }
            }
            return ack
        }

        // 1. Replay check: Check existing ACK on disk first
        if let ackData = try? Data(contentsOf: paths.ackFile(r.id)),
           let existingAck = try? jsonDecoder.decode(DispatchAck.self, from: ackData) {
            if existingAck.disposition == "rejected" {
                return existingAck
            }
            if let targetChatId = existingAck.chatId {
                guard let existingChat = chat(targetChatId) else {
                    return reject("Bất nhất: Chat đã bị xoá; không enqueue lại.", persist: false)
                }
                guard let receipt = existingChat.receipts.first(where: { $0.id == r.id }) else {
                    return reject("Bất nhất: Receipt trong chat đã mất; không enqueue lại.", persist: false)
                }
                if receipt.fingerprint != fp {
                    return reject("Xung đột: ID '\(r.id)' đã tồn tại với fingerprint khác.", persist: false)
                }
                pump()
                return existingAck
            }
        }

        // 2. Replay check: Check if receipt already committed to chat (e.g. crash before ACK write)
        if let existingChat = chats.first(where: { $0.receipts.contains(where: { $0.id == r.id }) }),
           let receipt = existingChat.receipts.first(where: { $0.id == r.id }) {
            if receipt.fingerprint != fp {
                try? persistAck(DispatchAck(id: r.id, disposition: existingChat.status == .running ? "started" : "queued",
                                            chatId: existingChat.id, fingerprint: receipt.fingerprint))
                return reject("Xung đột: ID '\(r.id)' đã tồn tại với fingerprint khác.", persist: false)
            }
            let ack = DispatchAck(id: r.id, disposition: existingChat.status == .running ? "started" : "queued", chatId: existingChat.id, fingerprint: fp)
            do {
                try persistAck(ack)
            } catch {
                lastIOError = "Lỗi ghi ACK \(ack.id): \(error.localizedDescription)"
            }
            pump()
            return ack
        }

        // 3. Permission and validity checks
        guard let from = chat(r.from), let fromAgent = team.agent(from.agentId) else {
            return reject("Chat gửi \(r.from) không tồn tại.")
        }
        guard team.role(fromAgent.roleId)?.canDispatch == true else {
            return reject("Vai trò của chat gửi không được phép giao việc.")
        }
        guard dispatchCount[r.from, default: 0] < team.maxDispatchPerTurn else {
            return reject("Vượt quá \(team.maxDispatchPerTurn) lần giao trong một lượt.")
        }
        guard let agent = team.agent(r.to) ?? team.agents.first(where: { $0.roleId == r.to }) else {
            return reject("Không có agent/vai trò '\(r.to)'. Xem: agentteam agents")
        }
        guard !r.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return reject("Nội dung giao việc trống.")
        }

        let isTab = r.tab != nil
        let targetId: String
        var targetChat: Chat
        if let tab = r.tab {
            guard let t = chat(tab), t.agentId == agent.id, tab != r.from else {
                return reject("Chat \(tab) không thuộc agent \(agent.id).")
            }
            targetId = t.id
            targetChat = t
        } else {
            targetId = shortId()
            targetChat = Chat(id: targetId, agentId: agent.id, title: r.title ?? "Nhiệm vụ", replyTo: r.from)
        }

        // 4. ATOMIC COMMIT to chat file on disk BEFORE updating RAM state
        let fromRole = team.role(fromAgent.roleId)?.name ?? fromAgent.roleId
        let taskText = "[Giao việc từ \(fromRole) \(fromAgent.id) · handoff \(r.id)]\n" + r.body

        var updatedDiskChat = targetChat
        updatedDiskChat.replyTo = r.from
        updatedDiskChat.receipts.append(DispatchReceipt(id: r.id, fingerprint: fp, date: Date()))
        updatedDiskChat.messages.append(Message(.task, taskText))
        updatedDiskChat.pending.append(Input(text: taskText, fromUser: false))
        if updatedDiskChat.status != .running {
            updatedDiskChat.status = .queued
        }

        do {
            try jsonEncoder.encode(updatedDiskChat).write(to: paths.chatFile(targetId), options: .atomic)
        } catch {
            lastIOError = "Lỗi ghi commit chat \(targetId): \(error.localizedDescription)"
            return reject("Lỗi I/O không commit được tệp chat: \(error.localizedDescription)", persist: false)
        }

        // 5. Update RAM state only after successful disk write
        if isTab {
            if let idx = chats.firstIndex(where: { $0.id == targetId }) {
                chats[idx] = updatedDiskChat
            }
        } else {
            chats.append(updatedDiskChat)
        }
        dispatchCount[r.from, default: 0] += 1

        let disposition = updatedDiskChat.status == .running ? "started" : "queued"
        let ack = DispatchAck(id: r.id, disposition: disposition, chatId: targetId, fingerprint: fp)
        do {
            try persistAck(ack)
        } catch {
            lastIOError = "Lỗi ghi ACK \(ack.id): \(error.localizedDescription)"
        }
        recordHealth()
        pump()
        return ack
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