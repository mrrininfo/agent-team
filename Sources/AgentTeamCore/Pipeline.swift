import Foundation

/// Where an active chat sits in the brief → card → build → verify → goal-check flow, for the Team page.
public enum PipelineStage: Int, CaseIterable, Identifiable, Sendable {
    case brief, card, build, verify, goal

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .brief: "Đề bài"
        case .card: "Thẻ việc"
        case .build: "Thực thi"
        case .verify: "Nghiệm thu"
        case .goal: "Kiểm tra cuối"
        }
    }

    /// nil for chats that are not running or queued, and for roles outside the flow (e.g. Research, plain Critic reviews).
    public static func of(_ c: Chat, team: Team) -> PipelineStage? {
        guard c.status == .running || c.status == .queued else { return nil }
        if c.goalCheckFor != nil { return .goal }
        switch team.agent(c.agentId)?.roleId {
        case "lead": return .brief
        case "planner": return .card
        case "worker": return .build
        case "testing": return .verify
        default: return nil
        }
    }
}
