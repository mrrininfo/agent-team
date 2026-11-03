import Foundation

public enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex, antigravity

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        }
    }

    public var binaryName: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .antigravity: "agy"
        }
    }

    /// Suggestions only: the model field stays free text because model names change often.
    public var suggestedModels: [String] {
        switch self {
        case .claude: ["opus", "sonnet", "haiku"]
        case .codex: ["gpt-6.1-sol", "gpt-6-luna"]
        case .antigravity: ["gemini-4-argon-high", "gemini-4-argon-medium", "gemini-3.8-flash-high", "gemini-3.8-flash-medium",
                             "claude-opus-5-5-high", "claude-sonnet-5-5-high", "claude-sonnet-5-5-medium", "gpt-oss-120b-medium"]
        }
    }

    /// "" = the CLI's default. Claude Code has no verified headless effort flag;
    /// Antigravity encodes effort in the model slug (e.g. gemini-3.8-flash-high).
    public var efforts: [String] {
        switch self {
        case .claude, .antigravity: [""]
        case .codex: ["", "low", "medium", "high"]
        }
    }
}

public struct Profile: Codable, Hashable, Sendable {
    public var provider: Provider
    public var model: String
    public var effort: String
    /// `Account.id` to run under; nil = the CLI's own login. A session started under one account is not resumed under another.
    public var account: String?

    public init(_ provider: Provider, _ model: String = "", effort: String = "", account: String? = nil) {
        self.provider = provider
        self.model = model
        self.effort = effort
        self.account = account
    }

    /// Provider + model (+ account), the unit a "model not found" or per-model quota applies to.
    public var modelKey: String { "\(provider.rawValue)|\(model)" + (account.map { "#\($0)" } ?? "") }
    /// Key of this account's quota windows in `Orchestrator.quotas`.
    public var quotaKey: String { provider.rawValue + (account.map { "#\($0)" } ?? "") }

    public var label: String {
        [provider.title, model.isEmpty ? "mặc định" : model, effort, account.map { AccountStore.find($0)?.label ?? "tk \($0)" } ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

public enum Access: String, Codable, CaseIterable, Sendable {
    case readOnly, write
    public var title: String { self == .write ? "Đọc/ghi" : "Chỉ đọc" }
}

public struct Role: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var contract: String
    public var access: Access
    public var canDispatch: Bool
    /// Tried in order after the agent's own profile when its provider is disabled or limited.
    public var fallbacks: [Profile]
    /// Work for this role must come with a task card (`--card`): a weaker coding model needs the skeleton spelled out.
    public var requiresCard: Bool?

    public init(id: String, name: String, contract: String, access: Access, canDispatch: Bool = false, fallbacks: [Profile] = [],
                requiresCard: Bool? = nil) {
        self.id = id
        self.name = name
        self.contract = contract
        self.access = access
        self.canDispatch = canDispatch
        self.fallbacks = fallbacks
        self.requiresCard = requiresCard
    }
}

public struct Agent: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var roleId: String
    public var profile: Profile

    public init(id: String = shortId(), roleId: String, profile: Profile) {
        self.id = id
        self.roleId = roleId
        self.profile = profile
    }
}

public struct Message: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case user, assistant, task, callback, handoff, system }
    public var id: UUID
    public var kind: Kind
    public var text: String
    public var date: Date

    public init(_ kind: Kind, _ text: String) {
        id = UUID()
        self.kind = kind
        self.text = text
        date = Date()
    }
}

public struct Input: Codable, Hashable, Sendable {
    public var text: String
    public var fromUser: Bool

    public init(text: String, fromUser: Bool) {
        self.text = text
        self.fromUser = fromUser
    }
}

public enum ChatStatus: String, Codable, Sendable {
    case idle, queued, running, done, failed, limited
}

public struct DispatchReceipt: Codable, Hashable, Sendable {
    public var id: String
    public var fingerprint: String
    public var date: Date

    public init(id: String, fingerprint: String, date: Date = Date()) {
        self.id = id
        self.fingerprint = fingerprint
        self.date = date
    }
}

/// Automatic loop between a doer chat and a reviewer, run by the app instead of the dispatcher:
/// debate (Planner ↔ Critic until "KHÔNG CÒN PHẢN BÁC LỚN") or verify (Worker → Testing until "KẾT LUẬN: ĐẠT").
/// Only the final outcome goes back to the dispatcher, which saves its turns.
/// Where a failed verification goes back to.
public enum FailureClass: String, CaseIterable, Sendable {
    case specGap = "SPEC_GAP", executionDefect = "EXECUTION_DEFECT", verifyDefect = "VERIFY_DEFECT", evidenceMissing = "EVIDENCE_MISSING"
}

public struct Relay: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Sendable { case debate, verify }
    public var mode: Mode
    public var reviewerAgent: String
    public var reviewerChat: String?
    /// Reviewer verdicts received so far.
    public var round = 0
    public var maxRounds: Int
    /// The original assignment, given to the reviewer with the first result.
    public var task: String
    /// Architect chat fixing the task card after a SPEC_GAP verdict.
    public var fixerChat: String?
    /// Failing criteria and `git diff --stat` of the previous round: equal again means the loop is not progressing.
    public var lastFailure: String?
    public var lastDiff: String?

    public init(mode: Mode, reviewerAgent: String, maxRounds: Int, task: String) {
        self.mode = mode
        self.reviewerAgent = reviewerAgent
        self.maxRounds = maxRounds
        self.task = task
    }

    public static let agreed = "KHÔNG CÒN PHẢN BÁC LỚN"

    /// The Verifier's last `PHÂN LOẠI:` line, read loosely (case, spacing) so a sloppy line still routes.
    public static func classify(_ text: String) -> FailureClass? {
        guard let line = text.components(separatedBy: .newlines).last(where: { $0.uppercased().contains("PHÂN LOẠI:") }),
              let r = line.uppercased().range(of: "PHÂN LOẠI:") else { return nil }
        let v = line.uppercased()[r.upperBound...].filter { !$0.isWhitespace && $0 != "`" && $0 != "*" }
        return FailureClass.allCases.first { v.hasPrefix($0.rawValue) }
    }

    /// Failing criteria lines (not the verdict line), to tell a repeated failure from progress.
    public static func failures(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .filter { $0.uppercased().contains("KHÔNG ĐẠT") && !$0.uppercased().contains("KẾT LUẬN") }
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
    }

    /// Verify mode: the last "KẾT LUẬN:" line decides; without one, any "KHÔNG ĐẠT" fails.
    public static func passed(_ text: String, mode: Mode) -> Bool {
        let t = text.uppercased()
        if mode == .debate { return t.contains(agreed) }
        if let r = t.range(of: "KẾT LUẬN:", options: .backwards) {
            let verdict = t[r.upperBound...].prefix(40)
            return verdict.contains("ĐẠT") && !verdict.contains("KHÔNG")
        }
        return !t.contains("KHÔNG ĐẠT")
    }
}

/// How long the last turn took: to the CLI's first output (start-up, session load, MCP) and in total.
public struct TurnTiming: Codable, Hashable, Sendable {
    public var firstSignal: TimeInterval?
    public var total: TimeInterval
    public var provider: String

    public init(firstSignal: TimeInterval?, total: TimeInterval, provider: String) {
        self.firstSignal = firstSignal
        self.total = total
        self.provider = provider
    }
}

public struct Chat: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var agentId: String
    public var title: String
    /// Chat that receives this chat's results (the one that dispatched the work).
    public var replyTo: String?
    public var sessionId: String?
    /// Profile that owns `sessionId`; a different effective profile cannot resume it.
    public var sessionProfile: Profile?
    /// Access mode under which `sessionId` was established; changing access requires a fresh session.
    public var sessionAccess: Access?
    /// Whether `sessionId` had dispatch capability; changing capability requires a fresh session.
    public var sessionCanDispatch: Bool?
    public var messages: [Message] = []
    public var pending: [Input] = []
    public var inFlight: [Input] = []
    /// Short recent activity lines (tool calls, partial answers) used in handoff packages.
    public var trail: [String] = []
    public var status: ChatStatus = .idle
    public var autoTurns = 0
    /// Uncached input + output tokens spent by this chat.
    public var tokens = 0
    public var activity = ""
    public var runningProfile: Profile?
    /// Atomic dispatch receipts recorded to enforce idempotency and prevent duplicate enqueues.
    public var receipts: [DispatchReceipt] = []
    /// Exact model name reported by the CLI (e.g. Claude init event), if available.
    public var reportedModel: String?
    /// Provider rawValue that reported the model, ensuring model metadata is scoped to matching provider.
    public var reportedModelProvider: String?
    public var relay: Relay?
    public var lastTiming: TurnTiming?
    /// Context size (tokens) after the last turn, and the model's window if the CLI reported it.
    public var context: Int?
    public var contextWindow: Int?
    /// Set when the context passed the team's compact threshold; the next idle moment compacts the session.
    public var compactDue: Bool?
    /// Critic chat checking the final answer of this Lead chat against its brief.
    public var goalCheckFor: String?
    /// The Lead's current answer was already checked; cleared by the user's next message.
    public var goalChecked: Bool?
    /// The Lead dispatched work under its current brief, so its final answer is worth checking.
    public var briefDispatched: Bool?

    public init(id: String = shortId(), agentId: String, title: String, replyTo: String? = nil) {
        self.id = id
        self.agentId = agentId
        self.title = title
        self.replyTo = replyTo
    }

    /// Title of a chat opened with +; replaced by the start of its first message.
    public static let untitled = "Chat mới"

    /// First line of a message, cut at a word near 50 characters, as a chat title.
    public static func title(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard line.count > 50 else { return line.isEmpty ? untitled : line }
        let cut = line.prefix(50)
        return String(cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut) + "…"
    }

    public func verifiedModel(for profile: Profile?) -> String? {
        guard let m = reportedModel, let p = profile, sessionProfile == p,
              reportedModelProvider == p.provider.rawValue else { return nil }
        return m
    }

    enum CodingKeys: String, CodingKey {
        case id, agentId, title, replyTo, sessionId, sessionProfile
        case sessionAccess, sessionCanDispatch
        case messages, pending, inFlight, trail, status, autoTurns, tokens, activity, runningProfile
        case receipts, reportedModel, reportedModelProvider, relay, lastTiming
        case context, contextWindow, compactDue, goalCheckFor, goalChecked, briefDispatched
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        agentId = try container.decode(String.self, forKey: .agentId)
        title = try container.decode(String.self, forKey: .title)
        replyTo = try container.decodeIfPresent(String.self, forKey: .replyTo)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        sessionProfile = try container.decodeIfPresent(Profile.self, forKey: .sessionProfile)
        sessionAccess = try container.decodeIfPresent(Access.self, forKey: .sessionAccess)
        sessionCanDispatch = try container.decodeIfPresent(Bool.self, forKey: .sessionCanDispatch)
        messages = try container.decodeIfPresent([Message].self, forKey: .messages) ?? []
        pending = try container.decodeIfPresent([Input].self, forKey: .pending) ?? []
        inFlight = try container.decodeIfPresent([Input].self, forKey: .inFlight) ?? []
        trail = try container.decodeIfPresent([String].self, forKey: .trail) ?? []
        status = try container.decodeIfPresent(ChatStatus.self, forKey: .status) ?? .idle
        autoTurns = try container.decodeIfPresent(Int.self, forKey: .autoTurns) ?? 0
        tokens = try container.decodeIfPresent(Int.self, forKey: .tokens) ?? 0
        activity = try container.decodeIfPresent(String.self, forKey: .activity) ?? ""
        runningProfile = try container.decodeIfPresent(Profile.self, forKey: .runningProfile)
        receipts = try container.decodeIfPresent([DispatchReceipt].self, forKey: .receipts) ?? []
        reportedModel = try container.decodeIfPresent(String.self, forKey: .reportedModel)
        reportedModelProvider = try container.decodeIfPresent(String.self, forKey: .reportedModelProvider)
        relay = try container.decodeIfPresent(Relay.self, forKey: .relay)
        lastTiming = try container.decodeIfPresent(TurnTiming.self, forKey: .lastTiming)
        context = try container.decodeIfPresent(Int.self, forKey: .context)
        contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow)
        compactDue = try container.decodeIfPresent(Bool.self, forKey: .compactDue)
        goalCheckFor = try container.decodeIfPresent(String.self, forKey: .goalCheckFor)
        goalChecked = try container.decodeIfPresent(Bool.self, forKey: .goalChecked)
        briefDispatched = try container.decodeIfPresent(Bool.self, forKey: .briefDispatched)
    }
}

public struct Team: Codable, Sendable {
    public var roles: [Role]
    public var agents: [Agent]
    public var disabledProviders: Set<Provider> = []
    public var limitedProviders: Set<Provider> = []
    /// Provider rawValue → when it hit its limit; it is retried after `limitCooldownMinutes`.
    public var limitedSince: [String: Date] = [:]
    /// Provider rawValue → when its limit resets, if known (from the error text or the quota bar); retried then
    /// instead of every `limitCooldownMinutes`. Optional so older team.json files decode.
    public var limitedUntil: [String: Date]?
    /// `Profile.modelKey`s the CLI rejected as missing/unavailable; skipped like a limited provider until cleared.
    public var badModels: Set<String>?
    /// `Profile.modelKey` → when its quota resets. Antigravity's quota is per model (Gemini Flash can be used up while
    /// gemini-argon still runs), so only that model is skipped and the role's other Antigravity fallbacks keep working.
    public var limitedModels: [String: Date]?
    /// `Account.id` → when that extra account's limit (or daily token cap) lifts. The default account uses `limitedProviders`.
    public var limitedAccounts: [String: Date]?
    public var limitCooldownMinutes = 30
    /// Provider rawValue → absolute binary path; empty means auto-detect from the login shell PATH.
    public var binaryPaths: [String: String] = [:]
    public var autoFailover = true
    public var maxConcurrent = 3
    public var callbackLimit = 4000
    public var maxAutoTurns = 12
    public var maxDispatchPerTurn = 6
    /// Max Planner ↔ Critic rounds (nil = 2). Optional so team.json files from older versions still decode.
    public var debateRounds: Int?
    /// Name shown instead of the folder name (nil = folder name).
    public var name: String?
    /// The project's own saved setup, offered as "Custom" in the preset menu; never shared with other projects.
    public var customSetup: TeamSetup?
    /// A running turn with no output for this many minutes is treated as hung (nil = 20).
    public var stallMinutes: Int?
    /// Compact a session once its context passes this % of the model's window (nil = 50, 0 = off).
    public var compactPercent: Int?
    public var compactAt: Int { compactPercent ?? 50 }
    /// Critic checks the Lead's final answer against the brief (nil = on).
    public var goalCheck: Bool?
    public var goalCheckOn: Bool { goalCheck ?? true }

    public init(roles: [Role], agents: [Agent]) {
        self.roles = roles
        self.agents = agents
    }

    public func role(_ id: String) -> Role? { roles.first { $0.id == id } }
    public func agent(_ id: String) -> Agent? { agents.first { $0.id == id } }

    public func usable(_ p: Profile) -> Bool {
        let accountFree = p.account.map { id in AccountStore.find(id)?.enabled == true && limitedAccounts?[id] == nil }
            ?? !limitedProviders.contains(p.provider)
        return !disabledProviders.contains(p.provider) && accountFree && !(badModels ?? []).contains(p.modelKey)
            && limitedModels?[p.modelKey] == nil
    }

    /// Each profile on the default account, then on the provider's other accounts in order, before the next fallback.
    public func effectiveProfile(for agent: Agent) -> Profile? {
        ([agent.profile] + (role(agent.roleId)?.fallbacks ?? [])).lazy.flatMap { p -> [Profile] in
            guard p.account == nil else { return [p] }
            return [p] + AccountStore.rotation(p.provider).map { a in var q = p; q.account = a.id; return q }
        }.first(where: usable)
    }

    public func roster() -> String {
        agents.map { a in
            let r = role(a.roleId)
            let p = effectiveProfile(for: a)?.label ?? "không khả dụng"
            return "- \(a.id) · \(r?.name ?? a.roleId) (role: \(a.roleId)) · \(p) · \(r?.access.title ?? "")"
        }.joined(separator: "\n")
    }

    /// Built-in template: analyse → critique → decide → build → verify.
    /// Planner and Critic run on different model families so the critique is not the same model agreeing with itself;
    /// fallbacks keep that split when a provider is off (Antigravity also serves Claude models).
    public static func starter() -> Team {
        let roles = [
            Role(id: "lead", name: "Lead", contract: """
                Điều phối và ra quyết định cuối. Không tự làm phần việc của vai trò khác.
                Việc code (worker là model nhanh nhưng cần kèm cặp):
                - Spec giao worker phải cụ thể: file cần sửa, việc từng bước, lệnh kiểm tra, tiêu chí đạt. Việc nhỏ thì tự viết spec ngắn;
                  việc lớn dùng spec của planner, gửi nguyên văn.
                - Kiểm chứng được bằng test thì giao testing viết test thất bại trước, rồi mới giao worker làm cho test pass.
                - Giao việc ghi rõ phạm vi tối thiểu đủ đáp ứng yêu cầu; không thêm tính năng phụ người dùng không yêu cầu.
                - Giao worker kèm `--verify testing`: Testing KHÔNG ĐẠT thì app tự gửi lại worker sửa (tối đa 3 vòng). Kết luận cuối
                  vẫn KHÔNG ĐẠT thì giao planner xem lại cách làm hoặc báo người dùng.
                - Worker hỏi lại vì mơ hồ: tự trả lời nếu đủ thông tin, không thì hỏi planner hoặc người dùng.
                Việc quan trọng/nhiều rủi ro (kiến trúc, tiền, dữ liệu, chiến lược) hoặc người dùng yêu cầu thảo luận:
                1. Giao planner phân tích và đề xuất phương án (giả định, rủi ro, tiêu chí đạt) kèm `--debate critic`: app tự chuyển
                   qua lại planner ↔ critic theo số vòng ở mục "Thảo luận"; bạn chỉ nhận bản chốt kèm ý kiến cuối của critic.
                2. Tự chốt quyết định, ghi vào .agentteam/decisions/<chủ-đề>.md: phương án, lý do, rủi ro còn lại, tiêu chí nghiệm thu.
                3. Giao worker thực hiện theo quyết định (kèm spec) với `--verify testing`, đưa đúng tiêu chí nghiệm thu đó.
                "Báo xong" chưa phải là đạt. Báo người dùng ngắn gọn, dễ hiểu: kết luận, bằng chứng, điểm còn tranh cãi.
                """, access: .write, canDispatch: true,
                fallbacks: [Profile(.claude, "opus"), Profile(.antigravity, "gemini-4-argon-high"), Profile(.antigravity, "claude-opus-5-5-high")]),
            Role(id: "planner", name: "Planner", contract: """
                Phân tích và đề xuất. Đọc mã nguồn/tài liệu liên quan, đưa ra 1-3 phương án kèm đánh đổi và một khuyến nghị;
                ưu tiên phương án đơn giản nhất đủ đáp ứng yêu cầu, không mở rộng phạm vi.
                Bắt buộc có: giả định, rủi ro, cách kiểm chứng, tiêu chí đạt. Khi nhận phản biện: chấp nhận/bác từng điểm
                kèm lý do, rồi đưa bản đề xuất đã sửa. Không sửa file dự án.
                Khi khuyến nghị dẫn tới code, kèm mục "Spec cho worker": file cần sửa, hàm/kiểu dữ liệu, các bước nhỏ theo thứ tự,
                lệnh kiểm tra. Viết sao cho người làm không phải tự đoán.
                """, access: .readOnly,
                fallbacks: [Profile(.codex, "gpt-6.1-sol"), Profile(.antigravity, "gemini-4-argon-medium")]),
            Role(id: "critic", name: "Critic", contract: """
                Phản biện độc lập. Tìm lỗ hổng trong đề xuất được gửi: giả định sai hoặc chưa kiểm chứng, rủi ro bị bỏ sót,
                trường hợp biên, chi phí ẩn, cách khác đơn giản hơn. Mỗi phản bác: mức độ (lớn/nhỏ), lý do, cách kiểm chứng.
                Không khen xã giao, không phản bác cho có. Khi không còn vấn đề đáng kể, ghi đúng câu "KHÔNG CÒN PHẢN BÁC LỚN".
                Không sửa file dự án.
                Từ vòng 2: chỉ xét các phản bác lớn trước đó đã được giải quyết chưa, và lỗi lớn mới nếu có; không nêu thêm lỗi nhỏ.
                """, access: .readOnly,
                fallbacks: [Profile(.claude, "opus"), Profile(.antigravity, "gemini-4-argon-medium")]),
            Role(id: "worker", name: "Worker", contract: """
                Thực hiện đúng phạm vi và spec được giao, lần lượt từng bước. Chỉ sửa các file trong spec; cần sửa file khác thì báo lại.
                Có test hoặc lệnh kiểm tra thì chạy trước khi báo; chỉ báo xong khi đã pass. Không sửa hay xoá test để cho pass.
                Báo cáo: file đã sửa, lệnh đã chạy và output thật (không ghi "đã pass" nếu chưa chạy).
                Gặp điều mơ hồ, spec không khả thi, hoặc sửa 2 lần vẫn lỗi: dừng và báo lại thay vì tự đoán.
                """, access: .write,
                fallbacks: [Profile(.antigravity, "claude-sonnet-5-5-high"), Profile(.claude, "sonnet")]),
            Role(id: "testing", name: "Testing", contract: """
                Hai loại việc; không sửa mã sản phẩm ở cả hai:
                - Viết test trước: viết test thể hiện đúng tiêu chí, chạy để xác nhận nó đang thất bại, báo đường dẫn test và lệnh chạy.
                - Nghiệm thu: đọc thay đổi, kiểm tra worker không sửa/xoá test, chạy test/build. Kết luận ĐẠT/KHÔNG ĐẠT cho từng tiêu chí
                  kèm bằng chứng (file:line, lệnh, output). KHÔNG ĐẠT thì nêu lỗi đủ cụ thể để worker sửa được.
                """, access: .write,
                fallbacks: [Profile(.antigravity, "gemini-3.8-flash-high"), Profile(.codex, "gpt-6-luna", effort: "medium")]),
        ]
        let agents = [
            // Lead mostly routes and Critic mostly checks: medium effort answers noticeably faster than high.
            Agent(roleId: "lead", profile: Profile(.codex, "gpt-6.1-sol", effort: "medium")),
            Agent(roleId: "planner", profile: Profile(.claude, "opus")),
            Agent(roleId: "critic", profile: Profile(.codex, "gpt-6.1-sol", effort: "medium")),
            Agent(roleId: "worker", profile: Profile(.antigravity, "gemini-3.8-flash-high")),
            Agent(roleId: "testing", profile: Profile(.claude, "sonnet")),
        ]
        var t = Team(roles: roles, agents: agents)
        t.maxConcurrent = 5
        t.debateRounds = 3
        t.maxAutoTurns = 30
        t.maxDispatchPerTurn = 5
        return t
    }

    public var setup: TeamSetup { TeamSetup(roles: roles, agents: agents) }

    /// The preset the current roles and agents equal; nil means the project's own Custom setup.
    public var preset: TeamPreset? { TeamPreset.allCases.first { $0.setup.sameShape(as: setup) } }

    /// Replaces roles and agents, keeping agent ids of matching roles so their chats stay attached.
    public mutating func apply(_ s: TeamSetup) {
        var free = agents
        agents = s.agents.map { a in
            var a = a
            if let i = free.firstIndex(where: { $0.roleId == a.roleId }) { a.id = free.remove(at: i).id }
            return a
        }
        roles = s.roles
    }
}

/// Roles + agents: the part of a team that presets set.
public struct TeamSetup: Codable, Hashable, Sendable {
    public var roles: [Role]
    public var agents: [Agent]

    public init(roles: [Role], agents: [Agent]) {
        self.roles = roles
        self.agents = agents
    }

    /// Same roles and the same provider/model per role; agent ids are random, so they are ignored.
    public func sameShape(as o: TeamSetup) -> Bool {
        roles == o.roles && agents.map { [$0.roleId, $0.profile.label] } == o.agents.map { [$0.roleId, $0.profile.label] }
    }
}

public enum TeamPreset: String, CaseIterable, Identifiable, Sendable {
    case standard, lite34, design, assistant
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: "Mặc định"
        case .lite34: "v3.4 rút gọn"
        case .design: "Design"
        case .assistant: "Assistant"
        }
    }

    public var setup: TeamSetup {
        switch self {
        case .standard: Team.starter().setup
        case .lite34: Self.lite34Setup
        case .design: Self.designSetup
        case .assistant: Self.assistantSetup
        }
    }

    /// Graphic design: brief → image → review → finishing. Codex is the only verified image generator,
    /// so its quota is kept for drawing and the other roles run on Antigravity.
    static var designSetup: TeamSetup {
        TeamSetup(roles: [
            Role(id: "lead", name: "Art Director", contract: """
                Art director: nhận yêu cầu thiết kế, điều phối, chốt bản giao. Không tự viết prompt hay vẽ.
                1. Yêu cầu thiếu thông tin quan trọng (mục đích, kích thước/tỉ lệ, chữ cần có, nơi đăng) thì hỏi người dùng tối đa 3 câu ngắn trước khi giao.
                2. Giao brief viết brief + prompt (gửi nguyên văn yêu cầu người dùng).
                3. Giao generator tạo ảnh theo prompt (lưu vào design/<tên-việc>/) kèm `--verify reviewer --rounds 2`, gửi kèm checklist của brief:
                   reviewer chấm ảnh, KHÔNG ĐẠT thì app tự gửi prompt đã sửa lại cho generator.
                4. Ảnh có chữ, hoặc cần kích thước/định dạng cụ thể: giao finisher hoàn thiện.
                5. Báo người dùng: đường dẫn các file, khác nhau thế nào, khuyến nghị chọn bản nào.
                Người dùng chọn/chê ảnh nào thì ghi ngắn gọn vào design/style-guide.md (thích gì, ghét gì, vì sao) để các lần sau làm đúng gu.
                """, access: .write, canDispatch: true,
                fallbacks: [Profile(.antigravity, "gemini-4-argon-high")]),
            Role(id: "brief", name: "Brief", contract: """
                Biến yêu cầu thành brief thiết kế. Đọc design/style-guide.md trước nếu có, và theo đúng nó.
                Brief gồm: mục đích, đối tượng xem, tỉ lệ/kích thước, bố cục, phong cách, bảng màu (mã hex), ánh sáng, chữ cần có (nguyên văn), điều cấm.
                Rồi viết 2-3 prompt tạo ảnh bằng tiếng Anh, mỗi prompt một hướng khác nhau rõ rệt, kèm một dòng giải thích hướng đó.
                Không đưa chữ dài vào prompt: chữ chính xác do finisher chèn sau. Kết thúc bằng checklist nghiệm thu 5-8 mục để reviewer chấm.
                """, access: .readOnly,
                fallbacks: [Profile(.antigravity, "gemini-4-argon-medium")]),
            Role(id: "generator", name: "Generator", contract: """
                Tạo ảnh bằng công cụ tạo ảnh, đúng nguyên văn các prompt được giao; không tự đổi ý tưởng.
                Lưu mỗi ảnh vào design/<tên-việc>/v<số>-<hướng>.png trong workspace (không ghi đè bản cũ); công cụ lưu chỗ khác thì chép về đó.
                Báo cáo: đường dẫn từng file, prompt đã dùng cho từng file. Không tạo được thì báo rõ lỗi, không giả vờ đã xong.
                """, access: .write),
            Role(id: "reviewer", name: "Reviewer", contract: """
                Mở và xem từng file ảnh được giao, chấm theo checklist của brief và design/style-guide.md.
                Mỗi ảnh: ĐẠT/KHÔNG ĐẠT từng mục, lỗi cụ thể (chữ sai chính tả, tay/mặt méo, bố cục lệch, sai màu, thừa chi tiết).
                Ảnh KHÔNG ĐẠT: viết lại prompt đã sửa, chỉ đổi phần gây lỗi. Xếp hạng các ảnh và nói rõ bản nào tốt nhất, vì sao.
                Không khen xã giao. Ảnh không mở được thì báo lại, không đoán nội dung.
                """, access: .readOnly,
                fallbacks: [Profile(.antigravity, "claude-sonnet-5-5-high")]),
            Role(id: "finisher", name: "Finisher", contract: """
                Hoàn thiện ảnh đã duyệt bằng công cụ trên máy (sips, Python/Pillow, SVG...): chèn chữ chính xác theo brief, cắt/đổi kích thước,
                thêm lề, xuất PNG/JPG/WebP theo yêu cầu. Lưu thành file mới design/<tên-việc>/final-<kích-thước>.<đuôi>, không ghi đè bản gốc.
                Báo cáo: file đã tạo, kích thước thật (đo lại sau khi xuất), lệnh đã chạy.
                """, access: .write,
                fallbacks: [Profile(.codex, "gpt-6-luna")]),
        ], agents: [
            Agent(roleId: "lead", profile: Profile(.antigravity, "claude-sonnet-5-5-high")),
            Agent(roleId: "brief", profile: Profile(.antigravity, "gemini-3.8-flash-high")),
            Agent(roleId: "generator", profile: Profile(.codex, "gpt-6.1-sol", effort: "medium")),
            Agent(roleId: "reviewer", profile: Profile(.antigravity, "gemini-4-argon-high")),
            Agent(roleId: "finisher", profile: Profile(.antigravity, "gemini-3.8-flash-high")),
        ])
    }

    /// Chatbot-style Q&A: the lead answers itself; research and checking only when needed.
    /// Brief → task card with a code skeleton → build → classified verification → goal check.
    /// Architect (strongest model) writes the skeleton so the fast Executor only fills it in; Critic stays on another family.
    static var lite34Setup: TeamSetup {
        TeamSetup(roles: [
            Role(id: "lead", name: "Lead", contract: """
                Điều phối và chốt đáp án cuối. Không tự làm phần việc của vai trò khác. Luôn bám đề bài đang ghim.
                Việc code đi đúng luồng:
                1. Giao architect viết thẻ việc (+ khung code) cho từng phần nhỏ (tối đa 3 file, khoảng 300 dòng); việc lớn/rủi ro thì kèm
                   `--debate critic`.
                2. Giao testing viết test nghiệm thu thất bại trước, theo mục "Test nghiệm thu" của thẻ.
                3. Giao worker: `--to worker --card .agentteam/tasks/<id>.md --verify testing`. App tự định tuyến khi KHÔNG ĐẠT:
                   lỗi spec về architect, lỗi test về testing, lỗi code về worker; dừng sớm khi không tiến triển.
                Việc tìm hiểu/tổng hợp tài liệu, dữ liệu: giao research (chỉ khi cần).
                Quyết định quan trọng ghi vào .agentteam/decisions/<chủ-đề>.md. "Báo xong" chưa phải là đạt.
                """, access: .write, canDispatch: true,
                fallbacks: [Profile(.claude, "opus"), Profile(.antigravity, "gemini-4-argon-medium")]),
            Role(id: "planner", name: "Architect", contract: """
                Thiết kế và viết khung để người làm không phải đoán. Mỗi phần việc là một thẻ `.agentteam/tasks/<id>.md` có đủ 5 mục:
                ## Mục tiêu · ## File được sửa · ## Khung code (chữ ký hàm/kiểu, hoặc đường dẫn file stub bạn đã tạo)
                · ## Test nghiệm thu (đường dẫn test + lệnh chạy) · ## Ngoài phạm vi.
                Được tạo file khung/stub (chữ ký, kiểu, TODO) nhưng KHÔNG viết phần ruột. Ưu tiên cách đơn giản nhất đủ đáp ứng đề bài.
                Việc phân tích/đề xuất: 1-3 phương án kèm đánh đổi, giả định, rủi ro, cách kiểm chứng, khuyến nghị.
                Nhận báo lỗi SPEC_GAP: sửa thẻ việc hoặc khung cho đúng, báo ngắn đã đổi gì.
                """, access: .write,
                fallbacks: [Profile(.codex, "gpt-6.1-sol", effort: "high"), Profile(.antigravity, "claude-opus-5-5-high")]),
            Role(id: "critic", name: "Critic", contract: """
                Phản biện độc lập và kiểm tra rủi ro. Tìm giả định sai, rủi ro bỏ sót, trường hợp biên, cách đơn giản hơn; mỗi điểm
                ghi mức độ (lớn/nhỏ), lý do, cách kiểm chứng. Không khen xã giao. Hết vấn đề đáng kể thì ghi đúng "KHÔNG CÒN PHẢN BÁC LỚN".
                Kiểm tra đáp án cuối: chấm từng tiêu chí của đề bài (đạt/không, vì sao), xem câu trả lời có đúng trọng tâm câu hỏi gốc,
                kết thúc bằng KẾT LUẬN: ĐẠT hoặc KẾT LUẬN: KHÔNG ĐẠT. Không sửa file dự án.
                """, access: .readOnly,
                fallbacks: [Profile(.antigravity, "gemini-4-argon-medium"), Profile(.claude, "sonnet")]),
            Role(id: "worker", name: "Executor", contract: """
                Làm đúng thẻ việc được giao. Chỉ sửa file trong mục "File được sửa"; giữ nguyên chữ ký trong "Khung code";
                không sửa hay xoá test. Chạy lệnh trong "Test nghiệm thu" trước khi báo; chỉ báo xong khi đã pass.
                Báo cáo: file đã sửa, lệnh đã chạy và output thật. Thẻ mơ hồ/không khả thi hoặc sửa 2 lần vẫn lỗi: dừng và nói rõ vì sao.
                """, access: .write,
                fallbacks: [Profile(.antigravity, "claude-sonnet-5-5-high"), Profile(.claude, "sonnet")], requiresCard: true),
            Role(id: "testing", name: "Verifier", contract: """
                Không sửa mã sản phẩm. Hai loại việc:
                - Viết test trước theo mục "Test nghiệm thu" của thẻ việc; chạy để xác nhận đang thất bại; báo đường dẫn và lệnh.
                - Nghiệm thu: đọc thay đổi, kiểm tra worker không sửa test và chỉ sửa file trong thẻ, architect không viết phần ruột;
                  chạy test/build. Kết luận từng tiêu chí kèm bằng chứng. KHÔNG ĐẠT thì thêm đúng một dòng
                  `PHÂN LOẠI: SPEC_GAP` (thẻ/khung sai hoặc thiếu) | `EXECUTION_DEFECT` (code sai) | `VERIFY_DEFECT` (test sai)
                  | `EVIDENCE_MISSING` (thiếu bằng chứng), rồi dòng KẾT LUẬN.
                """, access: .write,
                fallbacks: [Profile(.antigravity, "gemini-3.8-flash-high"), Profile(.codex, "gpt-6-luna", effort: "medium")]),
            Role(id: "research", name: "Research", contract: """
                Tìm hiểu và tổng hợp: đọc tài liệu, mã nguồn, dữ liệu được chỉ định; trả lời đúng câu hỏi được giao kèm nguồn
                (đường dẫn, file:line, link). Tách rõ điều đã kiểm chứng và điều suy đoán. Không sửa file dự án.
                """, access: .readOnly,
                fallbacks: [Profile(.antigravity, "gemini-3.8-flash-medium"), Profile(.claude, "haiku")]),
        ], agents: [
            Agent(roleId: "lead", profile: Profile(.codex, "gpt-6.1-sol", effort: "medium")),
            Agent(roleId: "planner", profile: Profile(.claude, "opus")),
            Agent(roleId: "critic", profile: Profile(.codex, "gpt-6.1-sol", effort: "medium")),
            Agent(roleId: "worker", profile: Profile(.antigravity, "gemini-3.8-flash-high")),
            Agent(roleId: "testing", profile: Profile(.claude, "sonnet")),
            Agent(roleId: "research", profile: Profile(.antigravity, "gemini-3.8-flash-high")),
        ])
    }

    static var assistantSetup: TeamSetup {
        TeamSetup(roles: [
            Role(id: "lead", name: "Assistant", contract: """
                Trợ lý trả lời trực tiếp như chatbot. Mặc định tự trả lời, không giao việc.
                Cách trả lời:
                - Trả lời đúng câu hỏi ngay câu đầu, rồi mới giải thích nếu cần. Ngắn gọn, cụ thể, có ví dụ/bước làm khi hữu ích.
                - Không lan man sang chủ đề người dùng không hỏi, không liệt kê mọi khả năng; đưa một khuyến nghị rõ ràng.
                - Không chắc thì nói không chắc và vì sao; không bịa số liệu, tên, đường link.
                - Câu hỏi mơ hồ đến mức trả lời sẽ sai hướng: hỏi lại đúng 1 câu ngắn.
                Chỉ giao việc khi thật sự cần:
                - researcher: cần thông tin mới/sau thời điểm kiến thức của bạn, số liệu cụ thể, đọc tài liệu/file dài.
                - checker: câu trả lời liên quan tiền, sức khoẻ, pháp lý, bảo mật, hoặc lệnh có thể làm mất dữ liệu.
                Nhận kết quả về thì tổng hợp lại thành câu trả lời ngắn, ghi nguồn nếu có.
                """, access: .readOnly, canDispatch: true,
                fallbacks: [Profile(.antigravity, "gemini-4-argon-medium"), Profile(.codex, "gpt-6-luna")]),
            Role(id: "researcher", name: "Researcher", contract: """
                Tra cứu đúng câu hỏi được giao: tìm trên web hoặc đọc file/tài liệu được chỉ định.
                Trả về: các dữ kiện tìm được (gạch đầu dòng), nguồn của từng dữ kiện (link hoặc file:dòng), ngày của thông tin nếu có.
                Chỉ báo điều tìm thấy, không suy diễn thêm. Không tìm được hoặc các nguồn mâu thuẫn thì nói rõ.
                Ngắn gọn, tối đa khoảng 15 dòng.
                """, access: .readOnly,
                fallbacks: [Profile(.codex, "gpt-6-luna")]),
            Role(id: "checker", name: "Checker", contract: """
                Kiểm tra câu trả lời nháp được gửi: sai sự thật, tính toán sai, thiếu cảnh báo quan trọng, lệnh nguy hiểm, lời khuyên quá chung chung.
                Trả về: ĐÚNG hoặc CẦN SỬA; nếu cần sửa thì liệt kê từng điểm cụ thể và cách sửa. Không viết lại toàn bộ câu trả lời.
                Không bới lỗi nhỏ về câu chữ.
                """, access: .readOnly,
                fallbacks: [Profile(.antigravity, "gemini-4-argon-medium")]),
        ], agents: [
            Agent(roleId: "lead", profile: Profile(.antigravity, "claude-sonnet-5-5-medium")),
            Agent(roleId: "researcher", profile: Profile(.antigravity, "gemini-3.8-flash-high")),
            Agent(roleId: "checker", profile: Profile(.codex, "gpt-6-luna", effort: "medium")),
        ])
    }
}

public func shortId() -> String {
    String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
}

/// First `n` characters, marking the cut.
public func clip(_ s: String, _ n: Int) -> String {
    s.count <= n ? s : String(s.prefix(n)) + "\n…[đã cắt \(s.count - n) ký tự]"
}

/// Last `n` characters, marking the cut.
public func tail(_ s: String, _ n: Int) -> String {
    s.count <= n ? s : "[…đã cắt \(s.count - n) ký tự]\n" + String(s.suffix(n))
}
