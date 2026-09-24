import Foundation

/// Restricts redirects to the configured HTTPS origin to protect Basic credentials.
final class SourceRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url, let next = request.url,
            Self.sameOrigin(original, next)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme == "https" && b.scheme == a.scheme && a.host?.lowercased() == b.host?.lowercased()
            && (a.port ?? 443) == (b.port ?? 443) && b.user == nil && b.password == nil
    }
}

actor CWAClient {
    static let shared = CWAClient()
    private let session: URLSession
    init(session: URLSession? = nil) {
        self.session =
            session
            ?? URLSession(
                configuration: .ephemeral, delegate: SourceRedirectPolicy(), delegateQueue: nil)
    }

    func fetchBooks(configuration: CWAConfiguration, password: String) async throws -> [Book] {
        let base = try configuration.baseURL()
        var url: URL? = base.appending(path: "opds/new")
        var visited = Set<URL>()
        var books: [Book] = []
        while let page = url {
            guard visited.insert(page).inserted, visited.count <= 500 else {
                throw SourceError.incomplete
            }
            let data = try await request(page, configuration: configuration, password: password)
            let feed = try OPDSFeed.parse(data, url: page, server: base.absoluteString)
            books += feed.books
            guard books.count <= 50_000 else { throw SourceError.incomplete }
            url = feed.next
            if url != nil { try await Task.sleep(for: .milliseconds(200)) }
        }
        return Array(
            Dictionary(books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values)
    }

    func request(_ url: URL, configuration: CWAConfiguration, password: String) async throws -> Data
    {
        let base = try configuration.baseURL()
        let basePath = "/" + base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard SourceRedirectPolicy.sameOrigin(base, url),
            basePath == "/" || url.path == basePath || url.path.hasPrefix(basePath + "/")
        else { throw SourceError.unsafeLink }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(
            "Basic " + Data("\(configuration.username):\(password)".utf8).base64EncodedString(),
            forHTTPHeaderField: "Authorization")
        request.setValue("Bookworms (read-only OPDS client)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await OfflineTestPolicy.data(for: request, session: session)
        guard let http = response as? HTTPURLResponse else { throw SourceError.incomplete }
        if http.statusCode == 401 { throw SourceError.credentials }
        if http.statusCode == 403 { throw SourceError.forbidden }
        guard http.statusCode == 200 else { throw SourceError.http(http.statusCode) }
        guard data.count <= 20_000_000 else { throw SourceError.incomplete }
        return data
    }
}

struct OPDSFeed {
    var books: [Book]
    var next: URL?

    static func parse(_ data: Data, url: URL, server: String) throws -> OPDSFeed {
        let delegate = OPDSParser(url: url, server: server)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.isFeed, !delegate.invalidEntry else {
            throw SourceError.invalidFeed
        }
        return OPDSFeed(books: delegate.books, next: delegate.next)
    }
}

private final class OPDSParser: NSObject, XMLParserDelegate {
    let url: URL
    let server: String
    var books: [Book] = []
    var next: URL?
    var isFeed = false
    var invalidEntry = false
    private var stack: [String] = []
    private var textStack: [String] = []
    private var entry: Entry?
    private struct Entry {
        var id = "", title = "", authors: [String] = [], summary = ""
        var year: Int?, cover: URL?, tags: [String] = []
        var acquisition = false
    }
    init(url: URL, server: String) {
        self.url = url
        self.server = server
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes: [String: String]
    ) {
        stack.append(elementName)
        textStack.append("")
        if stack.count == 1 {
            isFeed = elementName == "feed" && namespaceURI == "http://www.w3.org/2005/Atom"
        }
        if elementName == "entry" { entry = Entry() }
        if elementName == "category", let label = attributes["label"] ?? attributes["term"],
            attributes["scheme"]?.hasPrefix("custom_column:") != true
        {
            entry?.tags.append(label)
        }
        if elementName == "link", let href = attributes["href"],
            let link = URL(string: href, relativeTo: url)?.absoluteURL
        {
            let rel = attributes["rel"] ?? ""
            if entry != nil {
                if rel == "http://opds-spec.org/image" { entry?.cover = link }
                if rel.hasPrefix("http://opds-spec.org/acquisition") { entry?.acquisition = true }
            } else if rel == "next" {
                next = link
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !textStack.isEmpty else { return }
        textStack[textStack.count - 1] += string
    }
    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        self.parser(parser, foundCharacters: String(decoding: data, as: UTF8.self))
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let text = textStack.removeLast()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if entry != nil {
            let parent = stack.dropLast().last
            switch (elementName, parent) {
            case ("id", "entry"): entry?.id = value
            case ("title", "entry"): entry?.title = value
            case ("name", "author"): entry?.authors.append(value)
            case ("summary", "entry"), ("content", "entry"): entry?.summary = value
            case ("published", "entry"):
                entry?.year = Int(value.prefix(4)).flatMap { (1000...3000).contains($0) ? $0 : nil }
            default: break
            }
        }
        if elementName == "entry", let item = entry {
            if item.id.isEmpty || item.title.isEmpty || !item.acquisition {
                invalidEntry = true
            } else {
                books.append(
                    Book(
                        id: CWAConfiguration.bookID(server: server, identifier: item.id),
                        title: item.title,
                        author: item.authors.isEmpty
                            ? "Unknown author" : item.authors.joined(separator: ", "),
                        description: item.summary.isEmpty ? nil : item.summary,
                        coverURL: item.cover,
                        format: "Ebook", genres: item.tags, detailCoverURL: item.cover,
                        sources: [.cwa], isOwned: true, publicationYear: item.year))
            }
            entry = nil
        }
        stack.removeLast()
        // Preserve text inside XHTML summaries instead of discarding each nested element.
        if !textStack.isEmpty { textStack[textStack.count - 1] += text }
    }
}
