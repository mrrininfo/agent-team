# Thiết kế: Team v3.4 rút gọn

Ngày: 2026-11-03 · Trạng thái: chờ duyệt

## 1. Vấn đề cần giải quyết

Người dùng nói:

1. Giao Lead một việc dài. Cuối ngày, câu trả lời cuối lệch pha, chung chung, không đúng trọng tâm câu hỏi đầu. Lead như đã quên đề bài.
2. Worker (Gemini) code dễ lệch hướng. Spec do Lead hoặc Planner đưa xuống chưa đủ khung xương để nắn Gemini.
3. Cần đổi đội cho hiệu quả hơn. Trang Team cũng nên dễ nhìn hơn.

Nguyên nhân tìm được trong code hiện tại:

- **Đề bài chỉ có ở lượt đầu.** Hợp đồng vai trò và câu hỏi gốc chỉ gửi ở lượt đầu. Các lượt sau tiếp tục phiên cũ (`lead resumed without preamble`).
  - Sau một ngày, chat Lead có hơn 150 tin, phần lớn là báo cáo khoảng 4 KB.
  - App còn tự nén context ở mức 50% và có thể đổi phiên kèm gói bàn giao.
  - Sau mỗi lần nén, Lead chỉ còn bản tóm tắt của đề bài.
  - Gói bàn giao lấy tin đầu tiên của chat làm "nhiệm vụ gốc". Với chat Lead dùng lâu ngày, tin này thường không phải đề bài đang làm.
- **Spec cho Worker là văn xuôi.** Nó không có cấu trúc bắt buộc nào được kiểm tra, nên một spec thiếu file, thiếu chữ ký hàm hay thiếu lệnh test vẫn được giao đi.
- **Nghiệm thu không đạt luôn quay về Worker**, kể cả khi lỗi nằm ở spec. Worker sửa mãi một spec sai, hết 3 vòng rồi mới báo.
- **Không có bước nào kiểm tra đáp án cuối có trả lời đúng câu hỏi gốc không.**

## 2. Mục tiêu và tiêu chí thành công

- Đáp án cuối của Lead **bắt đầu bằng việc nhắc lại câu hỏi gốc** và trả lời đúng nó, kể cả sau nhiều lần nén hoặc đổi phiên.
- Mọi việc code giao cho Worker phải có **thẻ việc** đủ các mục bắt buộc. Thiếu mục thì app từ chối giao và báo rõ thiếu gì.
- Nghiệm thu không đạt thì **quay về đúng bước gây lỗi**: lỗi spec về Architect, lỗi code về Worker, lỗi test về Testing.
- Vòng sửa **không tiến triển** thì dừng sớm và báo Lead, không đốt hết số vòng.
- Đội mới là **một bộ cài sẵn**. Bộ hiện tại vẫn giữ nguyên và chuyển qua lại được.

Ngoài phạm vi: RAG/vector (graphify đã làm phần này), an toàn khi tác động ra bên ngoài và vai Operations (chưa có việc triển khai), 7 vai đầy đủ.

## 3. Đội: 5 ghế + 1 ghế tuỳ chọn

Giữ nguyên id vai trò (`lead`, `planner`, `critic`, `worker`, `testing`) để chat và lệnh cũ không gãy. Chỉ đổi tên hiển thị và hợp đồng.

| id | Tên mới | Việc | Quyền | Model đề xuất (khi có quota) |
|---|---|---|---|---|
| lead | Lead | Giữ đề bài, điều phối, chốt đáp án cuối | ghi | tầm trung (gpt-6.1-sol medium / argon-medium) |
| planner | Architect | Spec + **thẻ việc** + khung code (chữ ký hàm, stub), chỉ định test nghiệm thu | ghi (chỉ file khung + `.agentteam/tasks/`) | mạnh nhất (Claude opus / gpt-6.1-sol high) |
| worker | Executor | Điền phần ruột theo thẻ việc tới khi test đạt | ghi | Gemini flash-high |
| testing | Verifier | Viết test trước theo thẻ việc; nghiệm thu; **phân loại lỗi** | ghi (chỉ test) | tầm trung (sonnet / flash-high) |
| critic | Critic (Risk/QA) | Phản biện độc lập; **kiểm tra đáp án cuối khớp đề bài** | chỉ đọc | khác họ model với Architect |
| research (tuỳ chọn) | Research | Tìm hiểu, tổng hợp tài liệu/dữ liệu; chỉ gọi khi cần | chỉ đọc | Gemini flash (rẻ) |

Architect cần quyền ghi, vì viết khung code là cách nắn Gemini hiệu quả nhất. Phạm vi ghi bị giới hạn bằng hợp đồng và bị Verifier kiểm tra (Architect không viết phần ruột).

## 4. Cơ chế mới

### 4.1 Đề bài ghim (Brief)

- **File** `.agentteam/briefs/<chatId>.md` của mỗi chat Lead có hai phần:
  - `## Yêu cầu của người dùng (nguyên văn)`: **app** ghi thêm mọi tin người dùng gửi vào chat Lead, kèm giờ.
  - `## Tiêu chí xong` và `## Ngoài phạm vi`: **Lead** viết ở lượt đầu nhận việc mới và sửa khi người dùng đổi ý.
- **Gửi lại mỗi lượt:** mọi lượt của Lead (kể cả khi tiếp tục phiên cũ, sau khi nén hay đổi phiên) đều được app gắn khối "ĐỀ BÀI ĐANG LÀM" lên đầu prompt. Khối này cắt còn khoảng 3.000 ký tự: giữ tin đầu, 3 tin mới nhất và phần tiêu chí.
- **Gói bàn giao** lấy đề bài từ file này thay cho "tin đầu tiên của chat".
- **Việc mới:** nút "Việc mới" trong chat Lead đưa đề bài hiện tại vào `briefs/done/` và bắt đầu đề bài trống. Lead cũng có thể tự đóng bằng `agentteam brief done`.
- **Quy tắc trả lời của Lead:** đáp án cuối gửi người dùng mở đầu bằng "Câu hỏi: …" (nhắc lại câu hỏi nguyên văn), rồi trả lời từng tiêu chí trong file.

### 4.2 Thẻ việc (task card) cho Executor

- **File** `.agentteam/tasks/<id>.md`, các mục bắt buộc:
  `## Mục tiêu`, `## File được sửa`, `## Khung code` (chữ ký hàm/kiểu, hoặc đường dẫn file stub đã tạo),
  `## Test nghiệm thu` (đường dẫn test + lệnh chạy), `## Ngoài phạm vi`. Giới hạn khuyến nghị: tối đa 3 file, khoảng 300 dòng.
- **Cổng kiểm tra bằng code:** khi giao cho Worker bằng `agentteam dispatch --to worker ...`, app đòi tham số `--card <path>`. Thiếu tham số, không thấy file hoặc thiếu mục nào thì lệnh trả lỗi ghi rõ các mục còn thiếu. Việc không được xếp hàng.
- **Nội dung giao Worker** chính là nguyên văn thẻ việc, cộng phần ghi chú thêm.
- **Luồng:** Architect viết thẻ và khung code, Verifier viết test thất bại trước, rồi giao Executor (`--verify testing`).

### 4.3 Phân loại lỗi và quay về đúng bước

- **Mẫu kết luận của Verifier** khi KHÔNG ĐẠT:
  `KẾT LUẬN: KHÔNG ĐẠT` + dòng `PHÂN LOẠI: SPEC_GAP | EXECUTION_DEFECT | VERIFY_DEFECT | EVIDENCE_MISSING`.
- **Vòng `--verify` định tuyến theo phân loại** (sửa `relayStep`):
  - `EXECUTION_DEFECT` và `EVIDENCE_MISSING` gửi lại Executor, như hiện nay.
  - `SPEC_GAP` gửi Architect sửa thẻ việc hoặc khung code (qua chat Architect của việc đó, hoặc chat mới nếu chưa có), rồi giao lại Executor.
  - `VERIFY_DEFECT` gửi lại chính Verifier sửa test.
  - Thiếu dòng phân loại thì coi là `EXECUTION_DEFECT`, tức hành vi cũ.
- **Dừng khi không tiến triển (NO_PROGRESS):** hai vòng liên tiếp có cùng danh sách tiêu chí KHÔNG ĐẠT, hoặc `git diff` không đổi giữa hai vòng, thì dừng vòng lặp sớm. Lead nhận báo cáo "không tiến triển" kèm bằng chứng.

### 4.4 Kiểm tra đáp án cuối (goal check)

- **Khi nào chạy:** Lead trả lời người dùng (lượt không giao việc, chat không còn việc con đang chạy), và trong đề bài đã có việc được giao.
- **Cách chạy:** app tự gửi Critic gồm đề bài, đáp án và yêu cầu chấm từng tiêu chí, kết thúc bằng `KẾT LUẬN: ĐẠT/KHÔNG ĐẠT`.
  - **ĐẠT:** đáp án hiện cho người dùng như bình thường, kèm một dòng "đã kiểm tra khớp đề bài".
  - **KHÔNG ĐẠT:** nhận xét của Critic quay về Lead làm tiếp, tối đa 1 vòng. Sau đó đáp án vẫn hiện cho người dùng, kèm lưu ý của Critic.
- **Tắt/bật** trong mục Vận hành. Mỗi đáp án cuối tốn thêm 1 lượt Critic.

### 4.5 Giao diện trang Team

- **Phần "Đội":** mỗi vai một thẻ gồm tên, việc trong một câu, model đang dùng và đèn trạng thái, model dự phòng xếp gọn bên dưới. Thay cho danh sách dài hiện nay.
- **Phần "Luồng việc":** 5 cột Đề bài → Thẻ việc → Thực thi → Nghiệm thu → Kiểm tra cuối, hiện các chat đang ở từng bước. Bấm vào để mở chat.
- **Hợp đồng vai trò và cài đặt nâng cao** chuyển vào phần thu gọn.

## 5. Kiểm thử (assert trong `AgentTeamChecks`)

- Mọi lượt Lead, kể cả lượt tiếp tục phiên, có khối "ĐỀ BÀI ĐANG LÀM" chứa tin người dùng đầu tiên; gói bàn giao dùng đề bài.
- `dispatch --to worker` không có `--card`, hoặc thẻ thiếu mục, thì bị từ chối và nêu tên mục thiếu; thẻ đủ thì giao được.
- Vòng `--verify`: `SPEC_GAP` đến Architect rồi trở lại Executor; `VERIFY_DEFECT` đến Verifier; không có phân loại thì đi Executor.
- Hai vòng KHÔNG ĐẠT giống hệt nhau thì dừng và báo Lead.
- Goal check: ĐẠT thì không phát sinh lượt Lead thêm; KHÔNG ĐẠT thì có đúng 1 lượt Lead thêm.
- Bộ cài sẵn "v3.4 rút gọn" áp dụng được; bộ "Mặc định" không đổi.

## 6. Thứ tự làm

1. Đề bài ghim (4.1) và bộ cài sẵn mới (mục 3): chữa lỗi "Lead quên câu hỏi".
2. Thẻ việc và cổng kiểm tra (4.2): chữa lỗi "Gemini lệch hướng".
3. Phân loại lỗi và NO_PROGRESS (4.3).
4. Goal check (4.4).
5. Giao diện Team (4.5).

Mỗi bước là một commit riêng, có kiểm thử. Có thể dừng sau bất kỳ bước nào.

## 7. Rủi ro

- **Tốn token hơn:** khối đề bài khoảng 3.000 ký tự mỗi lượt Lead, cộng 1 lượt Critic mỗi đáp án cuối. Bù lại là ít vòng sửa sai và ít đáp án lệch.
- **Architect có quyền ghi** thì có thể lấn sang viết phần ruột. Hợp đồng cấm việc này và Verifier kiểm tra; nếu vẫn lấn thì quay về chỉ đọc kèm file stub.
- **Cổng thẻ việc cứng** có thể chặn cả việc rất nhỏ (sửa 1 dòng). Thẻ việc tối thiểu vẫn phải đủ các mục nhưng được viết ngắn.
