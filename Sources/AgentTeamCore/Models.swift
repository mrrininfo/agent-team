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

    public init(_ provider: Provider, _ model: String = "", effort: String = "") {
        self.provider = provider
        self.model = model
        self.effort = effort
    }

    public var label: String {
        [provider.title, model.isEmpty ? "mặc định" : model, effort].filter { !$0.isEmpty }.joined(separator: " · ")
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

    public init(id: String, name: String, contract: String, access: Access, canDispatch: Bool = false, fallbacks: [Profile] = []) {
        self.id = id
        self.name = name
        self.contract = contract
        self.access = access
        self.canDispatch = canDispatch
        self.fallbacks = fallbacks
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

    public init(id: String = shortId(), agentId: String, title: String, replyTo: String? = nil) {
        self.id = id
        self.agentId = agentId
        self.title = title
        self.replyTo = replyTo
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
        case receipts, reportedModel, reportedModelProvider
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
    }
}

public struct Team: Codable, Sendable {
    public var roles: [Role]
    public var agents: [Agent]
    public var disabledProviders: Set<Provider> = []
    public var limitedProviders: Set<Provider> = []
    /// Provider rawValue → when it hit its limit; it is retried after `limitCooldownMinutes`.
    public var limitedSince: [String: Date] = [:]
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

    public init(roles: [Role], agents: [Agent]) {
        self.roles = roles
        self.agents = agents
    }

    public func role(_ id: String) -> Role? { roles.first { $0.id == id } }
    public func agent(_ id: String) -> Agent? { agents.first { $0.id == id } }

    public func usable(_ p: Profile) -> Bool {
        !disabledProviders.contains(p.provider) && !limitedProviders.contains(p.provider)
    }

    public func effectiveProfile(for agent: Agent) -> Profile? {
        ([agent.profile] + (role(agent.roleId)?.fallbacks ?? [])).first(where: usable)
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
                Việc nhỏ, rõ ràng: giao thẳng worker, sau đó testing kiểm tra.
                Việc quan trọng/nhiều rủi ro (kiến trúc, tiền, dữ liệu, chiến lược) hoặc người dùng yêu cầu thảo luận:
                1. Giao planner phân tích và đề xuất phương án (ghi rõ giả định, rủi ro, tiêu chí đạt).
                2. Giao critic phản biện phương án đó (gửi nguyên văn đề xuất). Critic không thấy cuộc trò chuyện này.
                3. Chuyển phản biện cho planner bằng --tab để sửa, rồi gửi bản sửa lại cho critic (--tab); lặp tối đa số vòng ở mục
                   "Thảo luận" (người dùng có thể ghi số vòng khác trong yêu cầu). Dừng sớm khi critic ghi "KHÔNG CÒN PHẢN BÁC LỚN".
                4. Tự chốt quyết định, ghi vào .agentteam/decisions/<chủ-đề>.md: phương án, lý do, rủi ro còn lại, tiêu chí nghiệm thu.
                5. Giao worker thực hiện theo quyết định, rồi giao testing nghiệm thu theo đúng tiêu chí đó.
                "Báo xong" chưa phải là đạt. Báo người dùng: kết luận, bằng chứng, điểm còn tranh cãi.
                """, access: .write, canDispatch: true,
                fallbacks: [Profile(.antigravity, "claude-sonnet-5-5-high"), Profile(.antigravity, "gemini-4-argon-high")]),
            Role(id: "planner", name: "Planner", contract: """
                Phân tích và đề xuất. Đọc mã nguồn/tài liệu liên quan, đưa ra 1-2 phương án kèm đánh đổi và một khuyến nghị.
                Bắt buộc có: giả định, rủi ro, cách kiểm chứng, tiêu chí đạt. Khi nhận phản biện: chấp nhận/bác từng điểm
                kèm lý do, rồi đưa bản đề xuất đã sửa. Không sửa file dự án.
                """, access: .readOnly,
                fallbacks: [Profile(.antigravity, "claude-opus-5-5-high"), Profile(.antigravity, "gemini-4-argon-high")]),
            Role(id: "critic", name: "Critic", contract: """
                Phản biện độc lập. Tìm lỗ hổng trong đề xuất được gửi: giả định sai hoặc chưa kiểm chứng, rủi ro bị bỏ sót,
                trường hợp biên, chi phí ẩn, cách khác đơn giản hơn. Mỗi phản bác: mức độ (lớn/nhỏ), lý do, cách kiểm chứng.
                Không khen xã giao, không phản bác cho có. Khi không còn vấn đề đáng kể, ghi đúng câu "KHÔNG CÒN PHẢN BÁC LỚN".
                Không sửa file dự án.
                """, access: .readOnly,
                fallbacks: [Profile(.antigravity, "gemini-4-argon-high"), Profile(.antigravity, "claude-sonnet-5-5-high")]),
            Role(id: "worker", name: "Worker", contract: """
                Thực hiện đúng phạm vi được giao (theo quyết định nếu có). Báo cáo: file đã sửa, lệnh đã chạy và kết quả.
                Không mở rộng phạm vi; gặp điều mơ hồ hoặc quyết định không khả thi thì báo lại thay vì tự đoán.
                """, access: .write,
                fallbacks: [Profile(.antigravity, "claude-sonnet-5-5-high"), Profile(.antigravity, "gemini-3.8-flash-high")]),
            Role(id: "testing", name: "Testing", contract: """
                Nghiệm thu độc lập theo tiêu chí được giao: đọc thay đổi, chạy test/build/kiểm chứng.
                Kết luận ĐẠT/KHÔNG ĐẠT cho từng tiêu chí kèm bằng chứng (file:line, lệnh, output). Không sửa mã sản phẩm.
                """, access: .write,
                fallbacks: [Profile(.antigravity, "claude-sonnet-5-5-high"), Profile(.codex, "gpt-6.1-sol", effort: "medium")]),
        ]
        let agents = [
            Agent(roleId: "lead", profile: Profile(.codex, "gpt-6.1-sol", effort: "medium")),
            Agent(roleId: "planner", profile: Profile(.claude, "opus")),
            Agent(roleId: "critic", profile: Profile(.codex, "gpt-6.1-sol", effort: "high")),
            Agent(roleId: "worker", profile: Profile(.codex, "gpt-6.1-sol", effort: "high")),
            Agent(roleId: "testing", profile: Profile(.claude, "sonnet")),
        ]
        return Team(roles: roles, agents: agents)
    }

    public static var templateFileOverride: URL?

    /// User-saved template shared by all new projects (overrides the built-in one).
    public static var templateFile: URL {
        if let override = templateFileOverride { return override }
        if let env = ProcessInfo.processInfo.environment["AGENTTEAM_TEMPLATE_FILE"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentTeam/template.json")
    }

    public static func template() -> Team {
        (try? Data(contentsOf: templateFile)).flatMap { try? jsonDecoder.decode(Team.self, from: $0) } ?? starter()
    }

    public func saveAsTemplate() throws {
        var t = self
        t.limitedProviders = []
        t.limitedSince = [:]
        try FileManager.default.createDirectory(at: Team.templateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jsonEncoder.encode(t).write(to: Team.templateFile, options: .atomic)
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
