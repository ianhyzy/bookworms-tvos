import Foundation

/// Retains request counts and provider-reported usage without keys, prompts, or book data.
actor APIUsageStore {
    static let shared: APIUsageStore = {
        #if DEBUG && targetEnvironment(simulator)
            if let root = ScenarioNetwork.state.artworkRoot {
                return APIUsageStore(
                    url: root.deletingLastPathComponent().appending(path: "api-usage.json"))
            }
        #endif
        return APIUsageStore()
    }()
    private let url: URL
    private var records: [Entry]?

    init(url: URL = URL.cachesDirectory.appending(path: "Bookworms/api-usage.json")) {
        self.url = url
    }
    struct Entry: Codable {
        let date: Date
        let service: String
        let status: Int
        let duration: Double
        let inputTokens: Int?
        let outputTokens: Int?
        let cachedTokens: Int?
    }

    func record(service: String, status: Int, duration: Double, data: Data? = nil) {
        let root = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let usage = (root?["usageMetadata"] ?? root?["usage"]) as? [String: Any] ?? [:]
        let details =
            (usage["input_tokens_details"] ?? usage["prompt_tokens_details"]) as? [String: Any]
        let entry = Entry(
            date: Date(), service: service, status: status, duration: duration,
            inputTokens: (usage["promptTokenCount"] ?? usage["input_tokens"]
                ?? usage["prompt_tokens"]) as? Int,
            outputTokens: (usage["candidatesTokenCount"] ?? usage["output_tokens"]
                ?? usage["completion_tokens"]) as? Int,
            cachedTokens: (usage["cachedContentTokenCount"] ?? usage["cache_read_input_tokens"]
                ?? details?["cached_tokens"]) as? Int)
        if records == nil {
            records =
                (try? Data(contentsOf: url))
                .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        }
        records?.append(entry)
        records = Array((records ?? []).suffix(200))
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
