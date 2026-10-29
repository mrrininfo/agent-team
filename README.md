# Agent Team (macOS)

Tổ chức các phiên AI CLI (Claude Code, Codex, Antigravity `agy`) thành một team: Lead giao việc bằng
lệnh thật, app xếp hàng, chạy CLI tương ứng và chuyển kết quả về đúng chat đã giao việc.
Thiết kế: [docs/spec.md](docs/spec.md).

## Cài đặt
```bash
./build-app.sh
```
```bash
open dist/AgentTeam.app
```
Cần macOS 14+ và ít nhất một CLI đã đăng nhập: `claude`, `codex`, `agy`. App tự tìm CLI theo PATH
của login shell. Nếu không tìm thấy, nhập đường dẫn ở tab **Team & Provider**.

## Dùng
1. Chọn workspace (thư mục dự án). Trạng thái lưu tại `<workspace>/.agentteam/`, đã được git ignore.
2. Tab **Team & Provider**:
   - Mỗi vị trí (agent) chọn nhanh provider / model / effort.
   - Mỗi vai trò có hợp đồng, quyền, có được giao việc hay không, và danh sách fallback.
   - Tắt một provider (ví dụ hết gói Claude) thì mọi agent dùng nó tự rơi sang fallback. Muốn đổi
     hẳn thì dùng **Đổi hàng loạt**.
3. Bấm **+** cạnh Lead để mở chat và gửi yêu cầu. Lead giao việc bằng:
   ```bash
   agentteam dispatch --from <chatId> --to worker --new-task "Sửa nút Lưu" "phạm vi, đầu ra, bằng chứng"
   ```
   Kết quả của Worker tự quay về chat của Lead. Nhiều kết quả đến cùng lúc được gộp vào một lượt.
4. Khi bị limit:
   - Nếu bật tự chuyển, app chạy tiếp bằng fallback kèm gói bàn giao.
   - Nếu không, mở chat mới cùng vai trò, chọn **Tiếp tục việc từ [chat] → Chuyển việc**.

   - Hết thời gian chờ (mặc định 30 phút), app tự gỡ đánh dấu limit và chạy tiếp các chat đang chờ,
     không cần ai bấm (học từ cơ chế auto-resume của agent-teams-ai).

5. **Bộ mẫu team** (ngay trên danh sách vị trí): Mặc định, Design (tạo ảnh), Assistant (hỏi đáp kiểu chatbot).
   Sửa vai trò/vị trí thì thành **Custom (chưa lưu)**; bấm **Lưu Custom** để giữ. Custom chỉ thuộc dự án đó.
6. **Provider**: đèn xanh = đã đăng nhập, cam = đang bị limit, đỏ = chưa đăng nhập/không tìm thấy CLI, xám = tắt.
   **Login/Logout** mở Terminal chạy lệnh đăng nhập của CLI (Antigravity: gõ `/login` hoặc `/logout` trong TUI).
7. **Chat**: tin của bạn bên phải, AI bên trái. Đính kèm bằng nút kẹp giấy, kéo thả, hoặc ⌘V ảnh/file đã copy;
   file được chép vào `.agentteam/attachments/<chat>/` và gửi kèm đường dẫn cho agent.
   Đường dẫn file trong tin nhắn bấm được và mở trong **khung xem trước** bên phải (nút sidebar trên toolbar).
8. **Đổi tên dự án**: bấm vào tên ở đầu sidebar. Chỉ đổi tên hiển thị, thư mục trên ổ đĩa giữ nguyên.
9. **Treo / rớt mạng**: agent không in ra gì quá 20 phút (chỉnh trong Vận hành) thì app dừng nó cùng các lệnh con,
   chạy lại một lần kèm cảnh báo, treo lần nữa thì báo lỗi về người giao. Lỗi mạng thì giữ nguyên việc,
   tự thử lại theo thời gian giãn dần hoặc ngay khi có mạng.

## Tiết kiệm token
- Toolbar hiện tổng token, header của mỗi chat hiện token riêng (input không cache + output).
- Resume session của provider, nên hợp đồng và roster chỉ gửi ở lượt đầu.
- Gói bàn giao được dựng từ dữ liệu đã lưu, không gọi model.
- Kết quả gửi về người giao bị cắt theo giới hạn ký tự; muốn xem đủ thì dùng `agentteam show <chatId>`.
- Có giới hạn số lượt tự động, số lần giao việc mỗi lượt và số agent chạy song song.

## Kiểm tra
```bash
swift run AgentTeamChecks
```

## Giới hạn đã biết
- Lỗi limit nhận diện theo từ khoá (usage/rate limit, quota, 429…), vì các provider chưa công bố mã lỗi ổn định.
- Quyền "Chỉ đọc" chỉ được ép bằng công cụ với Claude. Với Codex/Antigravity, nó chỉ là ràng buộc
  trong hợp đồng, vì agent vẫn cần ghi inbox trong workspace.
- Chưa kiểm tra với CLI thật trên máy này. Cờ lệnh lấy từ tài liệu tháng 10/2026.
