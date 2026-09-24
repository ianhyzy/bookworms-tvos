import CoreText
import CryptoKit
import Foundation

struct GoogleFontFamily: Codable, Sendable {
    let family: String
    let category: String
    let isOpenSource: Bool?
}

struct DownloadedFont: Codable, Sendable {
    let family: String
    let postScriptName: String
    let filePath: String
    let licensePath: String
}

actor GoogleFontLibrary {
    static let shared = GoogleFontLibrary()
    private let root: URL
    private let session: URLSession
    init(
        root: URL = URL.cachesDirectory.appending(path: "Bookworms/google-fonts"),
        session: URLSession = .shared
    ) {
        self.root = root
        self.session = session
    }
    private var families: [GoogleFontFamily]?
    private var registered = Set<String>()

    func catalog() async throws -> [GoogleFontFamily] {
        if let families { return families }
        let cache = root.appending(path: "catalog.json")
        if let date = try? cache.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate,
            Date().timeIntervalSince(date) < 7 * 24 * 60 * 60,
            let saved = try? Data(contentsOf: cache), let all = try? decodeCatalog(saved)
        {
            families = all
            return all
        }
        var data: Data
        do {
            data = try await fetch(URL(string: "https://fonts.google.com/metadata/fonts")!)
            _ = try decodeCatalog(data)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: cache, options: .atomic)
        } catch {
            guard let saved = try? Data(contentsOf: cache) else { throw error }
            data = saved
        }
        let all = try decodeCatalog(data)
        families = all
        return all
    }

    private func decodeCatalog(_ data: Data) throws -> [GoogleFontFamily] {
        struct Catalog: Decodable { let familyMetadataList: [GoogleFontFamily] }
        let all = try JSONDecoder().decode(Catalog.self, from: Self.cleanJSON(data))
            .familyMetadataList
        guard all.count > 100 else { throw AIError.unavailableFont }
        return all
    }

    private func directory(family: String, weight: Int) -> URL {
        let key = SHA256.hash(data: Data("\(family):\(weight)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return root.appending(path: key)
    }

    private func cached(family: String, weight: Int) -> DownloadedFont? {
        let directory = directory(family: family, weight: weight)
        guard let data = try? Data(contentsOf: directory.appending(path: "font.json")),
            let stored = try? JSONDecoder().decode(DownloadedFont.self, from: data),
            FileManager.default.fileExists(atPath: directory.appending(path: "font.ttf").path),
            FileManager.default.fileExists(atPath: directory.appending(path: "LICENSE.txt").path)
        else { return nil }
        // App updates can move the sandbox; rebuild paths from the current cache directory.
        return DownloadedFont(
            family: stored.family, postScriptName: stored.postScriptName,
            filePath: directory.appending(path: "font.ttf").path,
            licensePath: directory.appending(path: "LICENSE.txt").path)
    }

    func download(family: String, weight: Int = 400) async throws -> DownloadedFont {
        if let font = cached(family: family, weight: weight) {
            if (try? register(font)) != nil { return font }
        }
        let catalog = try await catalog()
        guard let entry = catalog.first(where: { $0.family == family }), entry.isOpenSource != false
        else { throw AIError.invalidFont }
        let directory = directory(family: family, weight: weight)
        let manifestURL = directory.appending(path: "font.json")
        var components = URLComponents(string: "https://fonts.google.com/download/list")!
        components.queryItems = [URLQueryItem(name: "family", value: family)]
        let data = try await fetch(components.url!)
        struct Download: Decodable {
            let manifest: Manifest
            struct Manifest: Decodable {
                let files: [File]
                let fileRefs: [Reference]
                struct File: Decodable {
                    let filename: String
                    let contents: String
                }
                struct Reference: Decodable {
                    let filename: String
                    let url: URL
                }
            }
        }
        let manifest = try JSONDecoder().decode(Download.self, from: Self.cleanJSON(data)).manifest
        guard
            let license = manifest.files.first(where: {
                $0.filename.uppercased().contains("OFL")
                    || $0.filename.uppercased().contains("LICENSE")
            }),
            license.contents.contains("SIL OPEN FONT LICENSE")
                || license.contents.contains("Apache License")
        else { throw AIError.unavailableFont }
        let desired =
            [
                100: "Thin", 200: "ExtraLight", 300: "Light", 400: "Regular", 500: "Medium",
                600: "SemiBold", 700: "Bold", 800: "ExtraBold", 900: "Black",
            ][weight] ?? "Regular"
        let candidates = manifest.fileRefs.filter {
            $0.filename.hasSuffix(".ttf") && !$0.filename.contains("Italic")
        }
        guard
            let source = candidates.first(where: { $0.filename.hasSuffix("-\(desired).ttf") })
                ?? candidates.first(where: {
                    $0.filename.contains("[") || $0.filename.contains("VariableFont")
                }) ?? candidates.first,
            source.url.scheme == "https", source.url.host == "fonts.gstatic.com"
        else { throw AIError.unavailableFont }
        let fontData = try await fetch(source.url)
        guard fontData.count < 25_000_000 else { throw AIError.unavailableFont }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "font.ttf")
        let licenseFile = directory.appending(path: "LICENSE.txt")
        try fontData.write(to: file, options: .atomic)
        try license.contents.write(to: licenseFile, atomically: true, encoding: .utf8)
        guard
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL)
                as? [CTFontDescriptor],
            let descriptor = descriptors.first
        else { throw AIError.unavailableFont }
        let ctFont = CTFontCreateWithFontDescriptor(descriptor, 32, nil)
        let font = DownloadedFont(
            family: family, postScriptName: CTFontCopyPostScriptName(ctFont) as String,
            filePath: file.path, licensePath: licenseFile.path)
        try register(font)
        try JSONEncoder().encode(font).write(to: manifestURL, options: .atomic)
        return font
    }

    func restore(_ font: DownloadedFont, weight: Int) async throws -> DownloadedFont {
        return try await download(family: font.family, weight: weight)
    }

    private func register(_ font: DownloadedFont) throws {
        let measurement = PerformanceDiagnostics.begin("FontRegistration")
        defer { measurement.end() }
        guard !registered.contains(font.filePath) else { return }
        var error: Unmanaged<CFError>?
        let success = CTFontManagerRegisterFontsForURL(
            URL(filePath: font.filePath) as CFURL, .process, &error)
        let registrationError = error?.takeRetainedValue()
        // A variable font can be shared by several requested weights in the same process.
        guard
            success
                || registrationError.map({
                    CFErrorGetCode($0) == CTFontManagerError.alreadyRegistered.rawValue
                }) == true
        else {
            throw AIError.unavailableFont
        }
        registered.insert(font.filePath)
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 40
        let started = Date()
        let (data, response) = try await OfflineTestPolicy.data(for: request, session: session)
        await APIUsageStore.shared.record(
            service: "google-fonts", status: (response as? HTTPURLResponse)?.statusCode ?? 0,
            duration: Date().timeIntervalSince(started))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AIError.unavailableFont
        }
        return data
    }

    // Google prefixes these JSON documents with an anti-XSSI line, which is not JSON.
    static func cleanJSON(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix(")]}'"),
            let newline = text.firstIndex(of: "\n")
        else { return data }
        return Data(text[text.index(after: newline)...].utf8)
    }
}
