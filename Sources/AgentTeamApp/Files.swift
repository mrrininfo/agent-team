import AgentTeamCore
import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// A file or clipboard image waiting in the composer; copied into `.agentteam/attachments/<chat>/` on send.
struct Attachment: Identifiable {
    enum Source { case file(URL), image(Data) }
    let id = UUID()
    let source: Source
    let name: String
    let size: Int

    static let marker = Attachments.marker
    static let maxCount = 10
    static let maxBytes = 25_000_000

    static func file(_ u: URL) -> Attachment {
        let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Attachment(source: .file(u), name: u.lastPathComponent, size: size)
    }

    var thumbnail: NSImage {
        switch source {
        case .file(let u): Self.isImage(u) ? NSImage(contentsOf: u) ?? NSWorkspace.shared.icon(forFile: u.path) : NSWorkspace.shared.icon(forFile: u.path)
        case .image(let d): NSImage(data: d) ?? NSImage()
        }
    }

    static func isImage(_ u: URL) -> Bool { UTType(filenameExtension: u.pathExtension)?.conforms(to: .image) ?? false }

    static func paths(in text: String) -> [String] { Attachments.paths(in: text) }

    /// Keeps what fits the limits; the message explains what was left out.
    static func accept(_ items: [Attachment], existing: [Attachment]) -> ([Attachment], String?) {
        var ok: [Attachment] = [], skipped: [String] = []
        for a in items {
            if case .file(let u) = a.source, (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                skipped.append("\(a.name) (thư mục)")
            } else if a.size > maxBytes {
                skipped.append("\(a.name) (> \(maxBytes / 1_000_000) MB)")
            } else if existing.count + ok.count >= maxCount {
                skipped.append("\(a.name) (quá \(maxCount) file)")
            } else {
                ok.append(a)
            }
        }
        return (ok, skipped.isEmpty ? nil : "Bỏ qua: " + skipped.joined(separator: ", "))
    }

    /// Files copied in Finder, or an image (screenshot, copied picture). nil when the clipboard holds plain text.
    static func fromPasteboard(_ pb: NSPasteboard) -> [Attachment]? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map(file)
        }
        guard pb.string(forType: .string) == nil, let img = NSImage(pasteboard: pb),
              let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return nil }
        let name = "anh-dan-\(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")).png"
        return [Attachment(source: .image(png), name: name, size: png.count)]
    }

    /// Copies (never moves) each item into `dir` under a unique name; returns the stored files.
    static func store(_ items: [Attachment], in dir: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        return try items.enumerated().map { i, a in
            let dest = dir.appendingPathComponent("\(stamp)-\(i)-\(a.name)")
            switch a.source {
            case .file(let u): try FileManager.default.copyItem(at: u, to: dest)
            case .image(let d): try d.write(to: dest)
            }
            return dest
        }
    }
}

/// The right-hand preview pane: which file it shows and whether it is open.
@MainActor @Observable
final class PreviewState {
    var url: URL?
    var shown = false

    func open(_ u: URL) {
        url = u
        shown = true
    }
}

struct PreviewPane: View {
    let root: URL
    @Environment(PreviewState.self) private var preview
    @State private var recent: [URL] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    ForEach(recent, id: \.self) { u in
                        Button(u.path.replacingOccurrences(of: root.path + "/", with: "")) { preview.open(u) }
                    }
                    Divider()
                    Button("Mở file khác…") {
                        let panel = NSOpenPanel()
                        panel.directoryURL = root
                        if panel.runModal() == .OK, let u = panel.url { preview.open(u) }
                    }
                } label: {
                    Text(preview.url?.lastPathComponent ?? "Chọn file để xem").lineLimit(1)
                }
                .help("File mới sửa gần đây trong dự án (gồm báo cáo, quyết định, đính kèm của team)")
                Button { Task { recent = await Self.recentFiles(root) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Làm mới danh sách")
                if let u = preview.url {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([u]) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless).help("Hiện trong Finder")
                    // Opening hands the file to its default app; never for programs or scripts, which would run them.
                    Button { NSWorkspace.shared.open(u) } label: { Image(systemName: "arrow.up.forward.app") }
                        .buttonStyle(.borderless).help("Mở bằng ứng dụng mặc định")
                        .disabled(Self.isRunnable(u))
                }
            }
            .padding(8)
            Divider()
            if let u = preview.url {
                QuickLookView(url: u)
            } else {
                ContentUnavailableView("Chưa chọn file", systemImage: "doc.viewfinder",
                                       description: Text("Bấm vào đường dẫn/báo cáo trong chat, hoặc chọn từ danh sách phía trên."))
            }
        }
        .task(id: root) { recent = await Self.recentFiles(root) }
    }

    static func isRunnable(_ u: URL) -> Bool {
        ["app", "command", "sh", "zsh", "tool", "terminal", "workflow", "pkg"].contains(u.pathExtension.lowercased())
            || (FileManager.default.isExecutableFile(atPath: u.path) && UTType(filenameExtension: u.pathExtension)?.conforms(to: .text) != true
                && UTType(filenameExtension: u.pathExtension)?.conforms(to: .image) != true && u.pathExtension.lowercased() != "pdf")
    }

    /// 40 most recently changed files, skipping build output and VCS folders; inside `.agentteam` only what people read.
    static func recentFiles(_ root: URL) async -> [URL] {
        await Task.detached { scan(root) }.value
    }

    nonisolated static func scan(_ root: URL) -> [URL] {
        do {
            let skip: Set<String> = [".git", ".build", "node_modules", "DerivedData", "dist", ".swiftpm", "Pods", ".venv", "__pycache__", "graphify-out"]
            let teamDirs: Set<String> = ["reports", "decisions", "attachments", "notes"]
            var found: [(URL, Date)] = []
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                                                         options: [.skipsPackageDescendants]) else { return [] }
            var visited = 0
            for case let u as URL in e {
                visited += 1
                if visited > 20000 { break }
                let name = u.lastPathComponent
                let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let parent = u.deletingLastPathComponent().lastPathComponent
                if isDir {
                    if skip.contains(name) || (name.hasPrefix(".") && name != ".agentteam")
                        || (parent == ".agentteam" && !teamDirs.contains(name)) { e.skipDescendants() }
                    continue
                }
                if name.hasPrefix(".") || parent == ".agentteam" { continue }
                let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                found.append((u, d))
            }
            return found.sorted { $0.1 > $1.1 }.prefix(40).map(\.0)
        }
    }
}

/// Quick Look preview (images, PDF, text/markdown, office files, video…).
struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .normal)!
        v.autostarts = true
        v.previewItem = url as NSURL
        return v
    }

    func updateNSView(_ v: QLPreviewView, context: Context) {
        if (v.previewItem as? NSURL) as URL? != url { v.previewItem = url as NSURL }
    }
}
