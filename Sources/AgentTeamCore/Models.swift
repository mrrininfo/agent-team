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
    /// Name shown instead of the folder name (nil = folder name).
    public var name: String?
    /// The project's own saved setup, offered as "Custom" in the preset menu; never shared with other projects.
    public var customSetup: TeamSetup?
    /// A running turn with no output for this many minutes is treated as hung (nil = 20).
    public var stallMinutes: Int?

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
    case standard, design, assistant
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: "Mặc định"
        case .design: "Design"
        case .assistant: "Assistant"
        }
    }

    public var setup: TeamSetup {
        switch self {
        case .standard: Team.starter().setup
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
                3. Giao generator tạo ảnh theo prompt, lưu vào design/<tên-việc>/.
                4. Giao reviewer chấm ảnh theo brief. KHÔNG ĐẠT: gửi prompt đã sửa của reviewer cho generator bằng --tab; tối đa 2 vòng.
                5. Ảnh có chữ, hoặc cần kích thước/định dạng cụ thể: giao finisher hoàn thiện.
                6. Báo người dùng: đường dẫn các file, khác nhau thế nào, khuyến nghị chọn bản nào.
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
