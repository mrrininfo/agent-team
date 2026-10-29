import Darwin
import Foundation

public struct RunningProcessRecord: Codable, Hashable, Sendable {
    public var pid: Int32
    public var startTimeSec: Int
    public var startTimeUsec: Int32
    public var binary: String
    public var resolvedBinary: String?

    public init(pid: Int32, startTimeSec: Int, startTimeUsec: Int32, binary: String, resolvedBinary: String? = nil) {
        self.pid = pid
        self.startTimeSec = startTimeSec
        self.startTimeUsec = startTimeUsec
        self.binary = binary
        self.resolvedBinary = resolvedBinary ?? URL(fileURLWithPath: binary).resolvingSymlinksInPath().path
    }
}

public struct OrphanCleanupResult: Sendable {
    public var stopped: Int
    public var legacyChatIds: Set<String>
    public var unverifiableChatIds: Set<String>
    public var unverifiedChatIds: Set<String> { legacyChatIds.union(unverifiableChatIds) }

    public init(stopped: Int = 0, legacyChatIds: Set<String> = [], unverifiableChatIds: Set<String> = []) {
        self.stopped = stopped
        self.legacyChatIds = legacyChatIds
        self.unverifiableChatIds = unverifiableChatIds
    }

    public init(stopped: Int, unverifiedChatIds: Set<String>) {
        self.stopped = stopped
        self.legacyChatIds = []
        self.unverifiableChatIds = unverifiedChatIds
    }
}

/// Runs provider CLIs as child processes, one per turn.
@MainActor
public final class ProcessRunner {
    var processes: [String: Process] = [:]
    /// Folder holding the `agentteam` helper; prepended to PATH so agents can call it by name.
    public var helperDir: URL?
    public let searchPath: String

    public init(helperDir: URL?) {
        self.helperDir = helperDir
        searchPath = ProcessRunner.loginPath()
    }

    /// Obtains process start time via sysctl for exact ownership verification.
    nonisolated public static func processStartTime(pid: Int32) -> (Int, Int32)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var proc = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &proc, &size, nil, 0) == 0 else { return nil }
        return (Int(proc.kp_proc.p_starttime.tv_sec), proc.kp_proc.p_starttime.tv_usec)
    }

    /// Obtains executable binary path for PID via libproc proc_pidpath.
    nonisolated public static func processBinaryPath(pid: Int32) -> String? {
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buf.deallocate() }
        let len = proc_pidpath(pid, buf, 4096)
        guard len > 0 else { return nil }
        return String(cString: buf)
    }

    /// GUI apps get a minimal PATH; ask the login shell for the user's real one (nvm, homebrew, ~/.local/bin…).
    nonisolated public static func loginPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extras = ["\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-ilc", "printf '\\n__PATH__%s' \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        var shellPath = ""
        if (try? p.run()) != nil {
            let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            shellPath = s.components(separatedBy: "__PATH__").last ?? ""
        }
        let base = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        return ([shellPath] + extras + [base]).filter { !$0.isEmpty }.joined(separator: ":")
    }

    public func binary(for provider: Provider, override: String? = nil) -> String? {
        if let o = override, !o.isEmpty {
            let path = (o as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
        return searchPath.split(separator: ":").map { "\($0)/\(provider.binaryName)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func cancel(_ chatId: String) { processes[chatId]?.terminate() }

    static func recordRunning(_ paths: TeamPaths, _ chatId: String, _ record: RunningProcessRecord?) {
        var m: [String: RunningProcessRecord] = [:]
        if let data = try? Data(contentsOf: paths.runningFile),
           let existing = try? jsonDecoder.decode([String: RunningProcessRecord].self, from: data) {
            m = existing
        }
        if let record {
            m[chatId] = record
        } else {
            m.removeValue(forKey: chatId)
        }
        if m.isEmpty {
            try? FileManager.default.removeItem(at: paths.runningFile)
        } else {
            try? jsonEncoder.encode(m).write(to: paths.runningFile, options: .atomic)
        }
    }

    /// Stops provider processes left behind by a previous run of the app (crash, force quit, kill).
    /// Verifies exact ownership (PID, startTime, and binary path); never signals unverified or recycled PIDs.
    /// Returns count of stopped processes and set of unverified/legacy chat IDs that must NOT be auto-resumed.
    @discardableResult
    nonisolated public static func stopOrphans(_ paths: TeamPaths) -> OrphanCleanupResult {
        guard let data = try? Data(contentsOf: paths.runningFile) else {
            return OrphanCleanupResult(stopped: 0, unverifiedChatIds: [])
        }

        // Check for legacy schema [String: Int32]
        if let legacy = try? jsonDecoder.decode([String: Int32].self, from: data) {
            // Legacy schema: do NOT signal blindly. Block auto-resume for all related chats.
            return OrphanCleanupResult(stopped: 0, legacyChatIds: Set(legacy.keys), unverifiableChatIds: [])
        }

        guard let records = try? jsonDecoder.decode([String: RunningProcessRecord].self, from: data) else {
            return OrphanCleanupResult(stopped: 0, legacyChatIds: [], unverifiableChatIds: [])
        }

        var stopped = 0
        var unverifiable: Set<String> = []
        var remaining: [String: RunningProcessRecord] = [:]

        for (chatId, rec) in records {
            guard rec.pid > 1 else { continue }

            // Check if process is still alive
            if kill(rec.pid, 0) != 0 {
                // Already dead, entry is cleared
                continue
            }

            // Verify process ownership: startTime and binary path
            let currentStart = processStartTime(pid: rec.pid)
            let isRecycled = currentStart != nil && (currentStart!.0 != rec.startTimeSec || currentStart!.1 != rec.startTimeUsec)
            if isRecycled {
                // PID was recycled by the OS after the child exited; our child is dead. Do not signal.
                continue
            }

            let currentPath = processBinaryPath(pid: rec.pid)
            let resolvedRecBinary = rec.resolvedBinary ?? URL(fileURLWithPath: rec.binary).resolvingSymlinksInPath().path
            let resolvedCurrentPath = currentPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }

            let pathMatches = (currentPath == rec.binary)
                || (currentPath == resolvedRecBinary)
                || (resolvedCurrentPath != nil && (resolvedCurrentPath == rec.binary || resolvedCurrentPath == resolvedRecBinary))

            let isOwned = currentStart != nil
                && currentStart!.0 == rec.startTimeSec
                && currentStart!.1 == rec.startTimeUsec
                && pathMatches

            guard isOwned else {
                // Process is alive, startTime matches (or could not be read), but path cannot be verified:
                // DO NOT signal (safety), but mark unverified so auto-resume is blocked!
                unverifiable.insert(chatId)
                remaining[chatId] = rec
                continue
            }

            // Confirmed our process: send SIGTERM and wait up to 5 seconds
            kill(rec.pid, SIGTERM)
            var exited = false
            for _ in 0..<50 {
                usleep(100_000) // 100ms
                if kill(rec.pid, 0) != 0 {
                    exited = true
                    break
                }
            }

            if !exited {
                // Still running after 5s: send SIGKILL and check again
                kill(rec.pid, SIGKILL)
                for _ in 0..<10 {
                    usleep(100_000)
                    if kill(rec.pid, 0) != 0 {
                        exited = true
                        break
                    }
                }
            }

            if exited {
                stopped += 1
            } else {
                // Process could not be terminated: block auto-resume
                unverifiable.insert(chatId)
                remaining[chatId] = rec
            }
        }

        if remaining.isEmpty {
            try? FileManager.default.removeItem(at: paths.runningFile)
        } else {
            try? jsonEncoder.encode(remaining).write(to: paths.runningFile, options: .atomic)
        }

        return OrphanCleanupResult(stopped: stopped, legacyChatIds: [], unverifiableChatIds: unverifiable)
    }

    /// `binaryPath` is the workspace's custom path for this provider, if any (several workspaces share one runner).
    public func run(chatId: String, request: TurnRequest, cwd: URL, binaryPath: String? = nil,
                    onEvent: @escaping @MainActor (RunEvent) -> Void) async -> String? {
        let provider = request.profile.provider
        guard let bin = binary(for: provider, override: binaryPath) else {
            return "Không tìm thấy lệnh `\(provider.binaryName)`. Cài \(provider.title) CLI hoặc nhập đường dẫn trong tab Team."
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = provider.arguments(request)
        proc.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ([helperDir?.path].compactMap { $0 } + [searchPath]).joined(separator: ":")
        env["AGENTTEAM_CHAT"] = chatId
        env["AGENTTEAM_DIR"] = TeamPaths(workspace: cwd).root.path
        proc.environment = env
        let out = Pipe(), err = Pipe(), inp = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = provider.promptViaStdin ? inp : FileHandle.nullDevice
        let exited = AsyncStream<Int32> { c in
            proc.terminationHandler = { c.yield($0.terminationStatus); c.finish() }
        }
        do { try proc.run() } catch { return "Không chạy được \(bin): \(error.localizedDescription)" }
        let pid = proc.processIdentifier
        let start = Self.processStartTime(pid: pid) ?? (0, 0)
        let record = RunningProcessRecord(pid: pid, startTimeSec: start.0, startTimeUsec: start.1, binary: bin)
        processes[chatId] = proc
        let paths = TeamPaths(workspace: cwd)
        Self.recordRunning(paths, chatId, record)
        defer {
            processes[chatId] = nil
            Self.recordRunning(paths, chatId, nil)
        }

        if provider.promptViaStdin {
            let data = Data(request.prompt.utf8), h = inp.fileHandleForWriting
            Task.detached { h.write(data); try? h.close() }
        }
        let errHandle = err.fileHandleForReading
        let stderrTask = Task.detached { String(decoding: errHandle.readDataToEndOfFile(), as: UTF8.self) }

        var parser = OutputParser(provider)
        do {
            for try await line in out.fileHandleForReading.bytes.lines {
                for e in parser.feed(line) { onEvent(e) }
            }
        } catch {}
        var status: Int32 = 0
        for await s in exited { status = s }
        let stderr = await stderrTask.value
        return status == 0 ? nil : "exit \(status): " + tail(stderr.trimmingCharacters(in: .whitespacesAndNewlines), 1500)
    }
}
