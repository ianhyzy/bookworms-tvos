import Foundation
import TVServices

struct TopShelfBook: Codable, Sendable, Equatable {
    let id: Int
    let title: String
    let imageURL: URL
    /// The fraction of a current read completed, from 0 to 1. `nil` for books not in progress.
    var progress: Double? = nil
    var actionURL: URL { URL(string: "bookworms://book/\(id)")! }
}

enum BookLink {
    static func id(from url: URL) -> Int? {
        guard url.scheme == "bookworms", url.host == "book", url.query == nil,
            url.fragment == nil, url.user == nil, url.password == nil,
            url.pathComponents.count == 2, let id = Int(url.lastPathComponent), id > 0
        else { return nil }
        return id
    }
}

enum TopShelfSnapshot {
    static let group = "group.gay.ian.Bookworms"
    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appending(path: "Library/Caches/top-shelf.json")
    }

    /// Builds a **Now reading** section for books with progress and a **Recently read** section
    /// for the rest. The system draws a native progress bar from `playbackProgress`.
    static func content(for books: [TopShelfBook]) -> TVTopShelfSectionedContent? {
        let valid = books.filter { $0.id > 0 && $0.imageURL.scheme == "https" }.prefix(10)
        func section(_ title: String, _ books: [TopShelfBook]) -> TVTopShelfItemCollection<
            TVTopShelfSectionedItem
        >? {
            guard !books.isEmpty else { return nil }
            let section = TVTopShelfItemCollection(
                items: books.map { book in
                    let item = TVTopShelfSectionedItem(identifier: String(book.id))
                    item.title = book.title
                    item.imageShape = .poster
                    item.setImageURL(book.imageURL, for: .screenScale1x)
                    item.setImageURL(book.imageURL, for: .screenScale2x)
                    item.displayAction = TVTopShelfAction(url: book.actionURL)
                    if let progress = book.progress {
                        item.playbackProgress = min(1, max(0, progress))
                    }
                    return item
                })
            section.title = title
            return section
        }
        let sections = [
            section("Now reading", valid.filter { $0.progress != nil }),
            section("Recently read", valid.filter { $0.progress == nil }),
        ]
        .compactMap(\.self)
        return sections.isEmpty ? nil : TVTopShelfSectionedContent(sections: sections)
    }

    static func read() -> [TopShelfBook] {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
            let books = try? JSONDecoder().decode([TopShelfBook].self, from: data)
        else { return [] }
        return Array(books.filter { $0.id > 0 && $0.imageURL.scheme == "https" }.prefix(10))
    }

    static func write(_ books: [TopShelfBook]) throws {
        let measurement = PerformanceDiagnostics.begin("TopShelfWrite")
        defer { measurement.end() }
        guard let url = fileURL else { throw CocoaError(.fileNoSuchFile) }
        let data = try JSONEncoder().encode(Array(books.prefix(10)))
        if (try? Data(contentsOf: url)) == data { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        TVTopShelfContentProvider.topShelfContentDidChange()
    }
}
