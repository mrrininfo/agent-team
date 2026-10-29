import AgentTeamCore
import SwiftUI

func quotaColor(_ percent: Double) -> Color { percent < 70 ? .green : percent < 90 ? .orange : .red }

let vi = Locale(identifier: "vi_VN")

/// Slim bar at the bottom of the window: every limit window at a glance, details on click.
struct QuotaBar: View {
    let o: Orchestrator
    @State private var show = false

    var body: some View {
        HStack(spacing: 14) {
            Spacer()
            ForEach(Provider.allCases) { p in
                HStack(spacing: 6) {
                    Text(p == .antigravity ? "Antigravity" : p.title.components(separatedBy: " ")[0]).font(.caption.bold())
                    if let q = o.quotas[p.rawValue] {
                        // The bar shows the two most-used windows; the popover lists all of them.
                        ForEach(Array(q.windows.sorted { $0.usedPercent > $1.usedPercent }.prefix(2)), id: \.name) { w in
                            HStack(spacing: 3) {
                                Text(w.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                                ProgressView(value: min(max(w.usedPercent, 0), 100), total: 100)
                                    .tint(quotaColor(w.usedPercent)).frame(width: 46)
                                Text("\(Int(w.usedPercent.rounded()))%").font(.caption2.monospacedDigit())
                                    .foregroundStyle(quotaColor(w.usedPercent))
                            }
                        }
                    } else {
                        Text("—").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture { show.toggle() }
        .help("Quota tài khoản — bấm để xem chi tiết")
        .popover(isPresented: $show, arrowEdge: .top) { QuotaPanel(o: o) }
    }
}

struct QuotaPanel: View {
    let o: Orchestrator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Quota tài khoản").font(.headline)
            ForEach(Provider.allCases) { p in
                VStack(alignment: .leading, spacing: 6) {
                    Text(p.title).bold()
                    if let q = o.quotas[p.rawValue] {
                        ForEach(q.windows, id: \.name) { w in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text("Cửa sổ \(w.name)")
                                    Spacer()
                                    Text("\(Int(w.usedPercent.rounded()))% đã dùng").monospacedDigit().foregroundStyle(quotaColor(w.usedPercent))
                                }
                                ProgressView(value: min(max(w.usedPercent, 0), 100), total: 100).tint(quotaColor(w.usedPercent))
                                if let r = w.resetsAt {
                                    Text("Reset \(r.formatted(Date.RelativeFormatStyle(presentation: .named, locale: vi))) · \(r.formatted(.dateTime.locale(vi).weekday().day().month().hour().minute()))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text("Cập nhật \(q.updated.formatted(Date.RelativeFormatStyle(presentation: .named, locale: vi)))").font(.caption2).foregroundStyle(.tertiary)
                    } else {
                        switch o.quotaStatus(for: p) {
                        case .reading:
                            Text(p == .antigravity
                                 ? "Đang đọc từ agy (khoảng 20 giây)… Bấm Làm mới nếu chưa thấy."
                                 : "Đang đọc dữ liệu quota…")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        case .noBinary:
                            Text("Chưa tìm thấy lệnh `\(p.binaryName)`. Cài đặt CLI hoặc nhập đường dẫn trong tab Team.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        case .disabled:
                            Text("Provider \(p.title) đã bị tắt trong cấu hình.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        case .error(let msg, let at):
                            Text("Lỗi lúc \(at.formatted(.dateTime.locale(vi).hour().minute())): \(msg)")
                                .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        case .available:
                            EmptyView()
                        }
                    }
                }
                if p != Provider.allCases.last { Divider() }
            }
            HStack {
                Text("Token dự án này: \(o.totalTokens.formatted())").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Làm mới") { o.refreshQuotas(force: true) }
            }
        }
        .padding()
        .frame(width: 380)
    }
}
