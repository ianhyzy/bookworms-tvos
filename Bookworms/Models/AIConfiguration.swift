import CryptoKit
import Foundation

enum AIProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case google, anthropic, openAI, generic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .google: "Google Gemini"
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        case .generic: "Custom"
        }
    }
    var defaultModel: String {
        switch self {
        case .google: "gemini-3.8-flash"
        case .anthropic: "claude-sonnet-5"
        case .openAI: "gpt-4.1"
        case .generic: ""
        }
    }
}

struct AIConfiguration: Codable, Equatable, Sendable {
    var provider: AIProvider = .google
    var model: String = AIProvider.google.defaultModel
    var endpoint: String = ""

    var credentialAccount: String {
        if provider != .generic { return "ai-\(provider.rawValue)" }
        let digest =
            SHA256.hash(data: Data(endpoint.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "ai-generic-\(digest)"
    }

    func validatedURL() throws -> URL {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model.count <= 150,
            !model.contains(where: \.isWhitespace),
            provider != .google || !model.contains(where: { $0 == "/" || $0 == "?" || $0 == "#" })
        else { throw AIError.configuration }
        let value: String
        switch provider {
        case .google:
            value =
                "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        case .anthropic: value = "https://api.anthropic.com/v1/messages"
        case .openAI: value = "https://api.openai.com/v1/responses"
        case .generic: value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let url = URL(string: value), url.scheme == "https", url.host != nil,
            url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
        else { throw AIError.configuration }
        return url
    }
}

enum AIError: LocalizedError {
    case configuration, missingKey, invalidKey, invalidImage
    case request(Int)
    case invalidResponse, invalidFont, unavailableFont, missingCover
    var errorDescription: String? {
        switch self {
        case .configuration:
            "Enter a model ID and a valid HTTPS endpoint. Custom endpoints must accept OpenAI-compatible Chat Completions."
        case .invalidKey:
            "The API key contains spaces or line breaks. Copy the key again without extra text."
        case .invalidImage:
            "The cover images exceed the provider request limit. Use smaller cover images."
        case .missingKey: "Save an API key for this provider before generating spines."
        case .request(401):
            "The AI provider rejected the API key. Update it in Settings → AI spines."
        case .request(403):
            "The AI provider denied access. Check the key's permissions and model access."
        case .request(404):
            "The AI model or endpoint was not found. Check the model ID and endpoint in Settings → AI spines."
        case .request(429):
            "The AI provider's rate or usage limit was reached. Check your quota and try again later."
        case .request(500...599): "The AI provider is temporarily unavailable. Try again later."
        case .request(let code):
            "The AI provider returned HTTP \(code). Existing spines were preserved."
        case .invalidResponse:
            "The AI response did not contain a valid spine style. The existing style was preserved."
        case .invalidFont:
            "The AI selected a font outside the Google Fonts catalog. The existing style was preserved."
        case .unavailableFont: "The selected Google Font could not be downloaded with its license."
        case .missingCover: "No cover is available for this book. Its existing style was preserved."
        }
    }
}
