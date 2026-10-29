import AgentTeamCore
import Foundation

let usage = """
agentteam — giao việc giữa các agent trong Agent Team

  agentteam agents
  agentteam dispatch [--from <chatId>] --to <agentId|role> (--new-task "<tiêu đề>" | --tab <chatId>)
                     [--debate <role> | --verify <role>] [--rounds N] "<nội dung>" | -
  agentteam show <chatId>          # trả lời cuối của một chat
  agentteam status <handoffId>     # ACK của một lần giao

--from mặc định lấy từ biến AGENTTEAM_CHAT. Nội dung "-" đọc từ stdin.
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

let env = ProcessInfo.processInfo.environment
let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
guard let paths = env["AGENTTEAM_DIR"].map({ TeamPaths(workspace: URL(fileURLWithPath: $0).deletingLastPathComponent()) })
        ?? TeamPaths.find(from: cwd) else {
    fail("Không tìm thấy .agentteam (chạy trong workspace của Agent Team hoặc đặt AGENTTEAM_DIR).")
}

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

func readAck(_ id: String) -> DispatchAck? {
    (try? Data(contentsOf: paths.ackFile(id))).flatMap { try? jsonDecoder.decode(DispatchAck.self, from: $0) }
}

func printAck(_ a: DispatchAck) {
    print("handoffId: \(a.id)\ndisposition: \(a.disposition)")
    if let c = a.chatId { print("chatId: \(c)") }
    if let r = a.reason { print("reason: \(r)") }
}

switch command {
case "agents":
    print((try? String(contentsOf: paths.rosterFile, encoding: .utf8)) ?? "")

case "dispatch":
    let fromOpt = option("--from")
    let envChat = env["AGENTTEAM_CHAT"]
    if let fromOpt, let envChat, fromOpt != envChat {
        fail("--from '\(fromOpt)' khác AGENTTEAM_CHAT '\(envChat)'.")
    }
    let from = fromOpt ?? envChat
    let to = option("--to")
    let title = option("--new-task")
    let tab = option("--tab")
    let debate = option("--debate"), verify = option("--verify")
    let rounds = option("--rounds")
    guard debate == nil || verify == nil else { fail("Chỉ dùng một trong --debate hoặc --verify.") }
    guard rounds.map({ Int($0) != nil }) ?? true else { fail("--rounds phải là số.") }
    guard let from else { fail("Thiếu --from <chatId>.") }
    guard let to else { fail("Thiếu --to <agentId|role>.") }
    guard (title == nil) != (tab == nil) else { fail("Dùng đúng một trong --new-task \"<tiêu đề>\" hoặc --tab <chatId>.") }
    var body = args.joined(separator: " ")
    if body == "-" { body = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) }
    guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { fail("Thiếu nội dung giao việc.") }
    let req = DispatchRequest(from: from, to: to, title: title, tab: tab, body: body, reviewer: debate ?? verify,
                              mode: debate != nil ? .debate : verify != nil ? .verify : nil, rounds: rounds.flatMap { Int($0) })
    let tmp = paths.inbox.appendingPathComponent(".\(req.id).tmp")
    do {
        try jsonEncoder.encode(req).write(to: tmp)
        try FileManager.default.moveItem(at: tmp, to: paths.inbox.appendingPathComponent("\(req.id).json"))
    } catch { fail("Không ghi được inbox: \(error.localizedDescription)") }
    for _ in 0..<40 {
        if let a = readAck(req.id) {
            if let ackFp = a.fingerprint, ackFp != req.fingerprint {
                print("handoffId: \(req.id)\ndisposition: rejected\nreason: Xung đột: ID handoff trùng nhưng fingerprint khác.")
                exit(2)
            }
            printAck(a)
            exit(a.disposition == "rejected" ? 2 : 0)
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    print("handoffId: \(req.id)\ndisposition: pending (app chưa xác nhận; kiểm tra: agentteam status \(req.id))")

case "status":
    guard let id = args.first else { fail(usage) }
    if let a = readAck(id) { printAck(a) } else { print("handoffId: \(id)\ndisposition: pending") }

case "show":
    guard let id = args.first,
          let chat = (try? Data(contentsOf: paths.chatFile(id))).flatMap({ try? jsonDecoder.decode(Chat.self, from: $0) }) else {
        fail("Không tìm thấy chat.")
    }
    print("chat \(chat.id) · \(chat.title) · \(chat.status.rawValue)")
    print(chat.messages.last(where: { $0.kind == .assistant })?.text ?? "(chưa có trả lời)")

default:
    print(usage)
    exit(1)
}
