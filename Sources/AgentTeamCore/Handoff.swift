import Foundation

/// Builds the context a fresh session needs to take over a chat. Pure: no model call, no tokens spent.
public enum Handoff {
    public static func package(chat: Chat, role: Role?, reason: String, inputs: [Input], notes: String?, gitStatus: String?) -> String {
        var s = """
        # BÀN GIAO CÔNG VIỆC (Agent Team)
        Bạn tiếp quản công việc dang dở của vai trò \(role?.name ?? "?") (chat \(chat.id) · "\(chat.title)"). Lý do: \(reason).
        Không làm lại phần đã xong; kiểm tra trạng thái file thực tế trước khi sửa. Tiếp tục đúng điểm bị ngắt rồi báo cáo theo hợp đồng vai trò.
        """
        if let first = chat.messages.first(where: { [.user, .task, .handoff].contains($0.kind) }) {
            s += "\n\n## Nhiệm vụ gốc\n" + first.text
        }
        let open = inputs.map(\.text).filter { $0 != chat.messages.first?.text }
        if !open.isEmpty {
            s += "\n\n## Yêu cầu chưa hoàn thành\n" + open.joined(separator: "\n\n---\n\n")
        }
        let answers = chat.messages.filter { $0.kind == .assistant }.suffix(2)
        if !answers.isEmpty {
            s += "\n\n## Trả lời gần nhất của agent trước\n" + answers.map { clip($0.text, 1500) }.joined(separator: "\n\n---\n\n")
        }
        if !chat.trail.isEmpty {
            s += "\n\n## Hoạt động gần nhất trước khi ngắt\n" + chat.trail.suffix(15).map { "- " + $0 }.joined(separator: "\n")
        }
        if let notes, !notes.isEmpty {
            s += "\n\n## Ghi chú tiến độ của agent trước\n" + tail(notes, 4000)
        }
        if let gitStatus, !gitStatus.isEmpty {
            s += "\n\n## Trạng thái file (git status --porcelain)\n" + clip(gitStatus, 3000)
        }
        return s
    }
}
