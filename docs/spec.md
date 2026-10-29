# Agent Team (macOS) — Spec

## Mục tiêu
App macOS tổ chức các phiên AI CLI (Claude Code, Codex, Antigravity `agy`) thành một team:
giao việc bằng lệnh thật, định tuyến kết quả về đúng chat giao việc, đổi provider/model theo vai
trò nhanh, và chuyển giao công việc dang dở khi một agent bị limit — ưu tiên chạy liên tục và tiết kiệm token.

## Khái niệm
- **Role** (hợp đồng/JD): tên, contract, quyền `readOnly|write`, `canDispatch`, danh sách **fallback** (provider+model).
- **Agent**: một "nhân sự" gắn với role, có `Profile` = provider + model + effort. Đổi model không đổi vai.
- **Chat**: một phiên làm việc của agent. Lưu `sessionId` của provider để resume, `replyTo` = chat nhận kết quả.
- **Workspace**: thư mục dự án. Mọi trạng thái nằm ở `<workspace>/.agentteam/` (team.json, chats/, inbox/, notes/).

## Học từ các dự án tương tự
- *mcp_agent_mail* (inbox/outbox giữa agent) → giao tiếp bằng hộp thư file, có ACK `handoffId/disposition`.
- *Forge Orchestrator* (state dir chung, file locking) → trạng thái trong workspace, không cần server/MCP.
- *claw-orchestrator / myclaude* (định tuyến theo backend) → profile + fallback theo vai trò.
- Docs headless: `claude -p --output-format stream-json`, `codex exec --json` / `exec resume`, `agy -p --output-format stream-json` / `--conversation`.

## Luồng giao việc
1. User chat với Lead → app chạy CLI của Lead (headless, một process mỗi lượt).
2. Lead chạy `agentteam dispatch --from <chat> --to <agent|role> --new-task "<tiêu đề>" "<nội dung>"`
   (hoặc `--tab <chatId>`). Lệnh ghi `inbox/<id>.json`, chờ ACK (`queued|started|rejected`).
   Nói "sẽ giao" mà không gọi lệnh thì không có gì xảy ra.
3. App kiểm tra (chat gửi tồn tại, role được phép giao, target hợp lệ, ≤ N lần giao/lượt), tạo chat, xếp hàng.
4. Worker chạy trong phiên riêng. Kết thúc lượt → app gói kết quả (cắt ở `callbackLimit` ký tự,
   bản đầy đủ xem bằng `agentteam show <chat>`) và đưa vào hàng đợi chat `replyTo`.
5. Nhiều callback đến trong lúc Lead đang chạy được **gộp vào một lượt**.

## Liên tục & limit
- Lỗi được nhận diện là limit (usage/rate limit, quota, 429, resource_exhausted…) → provider bị đánh dấu `limited`.
- `autoFailover` bật: chat được xếp lại, chạy bằng profile khả dụng kế tiếp (agent.profile → fallbacks của role);
  vì phiên mới không resume được, app tự dựng **gói bàn giao** (nhiệm vụ gốc, yêu cầu dang dở, trả lời gần nhất,
  hoạt động gần nhất, file notes, `git status`). Không tốn token để tạo gói (dựng từ dữ liệu đã lưu).
- Thủ công: trong chat mới, "Tiếp tục việc từ [chat] → Chuyển việc", `replyTo` được chuyển theo.
- Tắt một provider (vd. hết Claude) → mọi agent dùng nó tự rơi sang fallback; có nút đổi hàng loạt.
- Mở lại app: chat đang chạy dở được xếp lại (resume session).

## Tiết kiệm token
- Resume session của provider; hợp đồng vai trò + roster chỉ gửi ở lượt đầu của phiên.
- Roster chỉ gửi cho role được giao việc. Kết quả chuyển tiếp bị cắt, chi tiết lấy theo yêu cầu.
- Giới hạn lượt tự động liên tiếp (`maxAutoTurns`) để chặn vòng lặp Lead↔Worker.
- Giới hạn số process chạy song song (`maxConcurrent`).

## Quyền
- Claude: `write` → `--dangerously-skip-permissions`; `readOnly` → `--allowedTools` chỉ đọc + `agentteam`.
- Codex: `--sandbox workspace-write` (cần ghi inbox trong workspace); `readOnly` chỉ ràng buộc bằng contract.
- Antigravity: `--dangerously-skip-permissions` (headless không duyệt được); `readOnly` chỉ ràng buộc bằng contract.

## Thành phần
- `AgentTeamCore`: models, provider adapters (args + parser + limit), inbox, handoff, orchestrator, process runner.
- `agentteam`: CLI (`agents`, `dispatch`, `show`, `status`).
- `AgentTeamApp`: SwiftUI (sidebar chat theo agent, chat view, team board chọn nhanh provider/model/effort).
- `AgentTeamChecks`: self-check bằng assert (máy chỉ có Command Line Tools, không có XCTest/Testing).
