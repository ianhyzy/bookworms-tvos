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

    /// Downloads and registers `family`, and returns its upright face nearest `weight`. Throws
    /// `AIError.invalidFont` for a blocked family, such as Impact, before reading the cache or
    /// the network.
    func download(family: String, weight: Int = 400) async throws -> DownloadedFont {
        guard SpineFontPolicy.allows(family) else { throw AIError.invalidFont }
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
        let candidates = manifest.fileRefs.filter {
            $0.filename.hasSuffix(".ttf") && !$0.filename.contains("Italic")
        }
        let chosen = Self.fileName(for: weight, in: candidates.map(\.filename))
        guard let source = candidates.first(where: { $0.filename == chosen }),
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
            let ctFont = Self.uprightFace(in: descriptors, nearest: weight)
        else { throw AIError.unavailableFont }
        let font = DownloadedFont(
            family: family, postScriptName: CTFontCopyPostScriptName(ctFont) as String,
            filePath: file.path, licensePath: licenseFile.path)
        try register(font)
        try JSONEncoder().encode(font).write(to: manifestURL, options: .atomic)
        return font
    }

    /// Returns the font file to download for `weight` from a family's upright `.ttf` file names,
    /// as the iPhone companion chooses it: the static file of that weight, else the variable
    /// file, else the static file of the nearest weight, else the first file.
    ///
    /// A static file names its weight as a suffix, such as "Kalam-Bold.ttf". Of two equally
    /// near static files, a weight above 500 takes the heavier and any other the lighter.
    static func fileName(for weight: Int, in names: [String]) -> String? {
        let weights = [
            "Thin": 100, "ExtraLight": 200, "Light": 300, "Regular": 400, "Medium": 500,
            "SemiBold": 600, "Bold": 700, "ExtraBold": 800, "Black": 900,
        ]
        let nearestStatic =
            names
            .compactMap { name -> (name: String, weight: Int)? in
                guard let style = name.dropLast(".ttf".count).split(separator: "-").last,
                    let fileWeight = weights[String(style)]
                else { return nil }
                return (name, fileWeight)
            }
            .min { nearer($0.weight, than: $1.weight, to: weight) }
        if let nearestStatic, nearestStatic.weight == weight { return nearestStatic.name }
        let variable = names.first { $0.contains("[") || $0.contains("VariableFont") }
        return variable ?? nearestStatic?.name ?? names.first
    }

    /// Returns the upright face nearest `weight` in `descriptors`, or `nil` when every face is
    /// italic or slanted. Of two equally near faces, a weight above 500 takes the heavier and any
    /// other the lighter; the lower PostScript name breaks a remaining tie.
    static func uprightFace(in descriptors: [CTFontDescriptor], nearest weight: Int) -> CTFont? {
        descriptors.map { CTFontCreateWithFontDescriptor($0, 32, nil) }
            .filter(SpineFontPolicy.isUpright)
            .min { lhs, rhs in
                let (left, right) = (cssWeight(of: lhs), cssWeight(of: rhs))
                guard left == right else { return nearer(left, than: right, to: weight) }
                return (CTFontCopyPostScriptName(lhs) as String)
                    < (CTFontCopyPostScriptName(rhs) as String)
            }
    }

    /// Returns the upright face of `family` nearest `weight` among the faces this process can
    /// draw, including fonts registered after a download, or `nil` when it has none.
    static func registeredFace(family: String, nearest weight: Int) -> CTFont? {
        let query = CTFontDescriptorCreateWithAttributes(
            [kCTFontFamilyNameAttribute: family] as CFDictionary)
        // The family is mandatory, so a missing family matches nothing rather than a fallback.
        let mandatory = Set([kCTFontFamilyNameAttribute as String]) as CFSet
        let faces = CTFontDescriptorCreateMatchingFontDescriptors(query, mandatory)
        return uprightFace(in: faces as? [CTFontDescriptor] ?? [], nearest: weight)
    }

    /// Returns the CSS weight (100...900) nearest a face's Core Text weight trait.
    ///
    /// The table holds the traits Core Text reports for Google Fonts files at each weight, as
    /// the iPhone companion maps them. They differ from the `UIFont.Weight` constants above 700
    /// and below 300.
    static func cssWeight(of font: CTFont) -> Int {
        let traits = CTFontCopyTraits(font) as? [CFString: Any]
        let trait = (traits?[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
        let table: [Double] = [-0.6, -0.4, -0.23, 0, 0.2, 0.3, 0.4, 0.6, 0.8]
        let index = table.indices.min { abs(table[$0] - trait) < abs(table[$1] - trait) } ?? 3
        return (index + 1) * 100
    }

    private static func nearer(_ lhs: Int, than rhs: Int, to weight: Int) -> Bool {
        let (left, right) = (abs(lhs - weight), abs(rhs - weight))
        guard left == right else { return left < right }
        return weight > 500 ? lhs > rhs : lhs < rhs
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
