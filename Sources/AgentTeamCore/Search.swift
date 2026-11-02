import Foundation

/// Keyword search over a project's chats (titles and messages), newest first.
public enum ChatSearch {
    public struct Hit: Identifiable, Hashable, Sendable {
        public var id: String { "\(chatId)/\(messageId?.uuidString ?? "title")" }
        public let chatId: String
        public let messageId: UUID?
        public let date: Date?
        public let snippet: String
    }

    /// Case- and diacritic-insensitive, so "tiep tuc" finds "Tiếp tục". Queries under 2 characters return nothing.
    public static func find(_ query: String, in chats: [Chat], limit: Int = 200) -> [Hit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var hits: [Hit] = []
        for c in chats {
            if c.title.range(of: q, options: opts) != nil {
                hits.append(Hit(chatId: c.id, messageId: nil, date: c.messages.last?.date, snippet: c.title))
            }
            for m in c.messages {
                guard let r = m.text.range(of: q, options: opts) else { continue }
                hits.append(Hit(chatId: c.id, messageId: m.id, date: m.date, snippet: snippet(m.text, around: r)))
            }
        }
        return Array(hits.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(limit))
    }

    static func snippet(_ text: String, around r: Range<String.Index>) -> String {
        let start = text.index(r.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(r.upperBound, offsetBy: 100, limitedBy: text.endIndex) ?? text.endIndex
        let body = text[start..<end].replacingOccurrences(of: "\n", with: " ")
        return (start > text.startIndex ? "…" : "") + body + (end < text.endIndex ? "…" : "")
    }
}
