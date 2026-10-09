import Foundation

public enum SystemTwoProvider: String, CaseIterable, Identifiable, Sendable {
    case ollama
    case copilot
    case openAI = "openai"
    case anthropic
    case gemini

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ollama: "Ollama (local, offline)"
        case .copilot: "GitHub Copilot (CLI)"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic Claude"
        case .gemini: "Google Gemini"
        }
    }

    public var needsAPIKey: Bool {
        switch self {
        case .openAI, .anthropic, .gemini: true
        case .ollama, .copilot: false
        }
    }

    /// Starting point only: the Settings window can load the provider's real model list.
    public var defaultModel: String {
        switch self {
        case .ollama: "gemma4:e4b-it-qat"
        case .copilot: "claude-haiku-5.5"
        case .openAI: "gpt-5.4-mini"
        case .anthropic: "claude-haiku-4-5"
        case .gemini: "gemini-3.8-flash"
        }
    }
}

public struct SystemTwoConfiguration: Sendable, Equatable {
    public var provider: SystemTwoProvider
    public var model: String
    public var apiKey: String?
    public var copilotPath: String?

    public init(provider: SystemTwoProvider, model: String, apiKey: String? = nil, copilotPath: String? = nil) {
        self.provider = provider
        self.model = model
        self.apiKey = apiKey
        self.copilotPath = copilotPath
    }

    public var displayName: String {
        "\(provider.displayName) · \(model)"
    }

    public func client() throws -> any ChatCompleting & ModelListing {
        if provider.needsAPIKey, apiKey?.isEmpty ?? true {
            throw ProviderError.missingAPIKey(provider.displayName)
        }
        let key = apiKey ?? ""
        switch provider {
        case .ollama:
            return OllamaClient(model: model)
        case .copilot:
            guard let copilotPath, FileManager.default.isExecutableFile(atPath: copilotPath) else {
                throw ProviderError.commandFailed(String(localized: "Copilot CLI not found. Set its path in Settings."))
            }
            return CopilotCLIClient(executable: URL(filePath: copilotPath), model: model)
        case .openAI:
            return OpenAICompatibleClient(
                service: "OpenAI", baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: key, model: model
            )
        case .anthropic:
            return AnthropicClient(apiKey: key, model: model)
        case .gemini:
            return OpenAICompatibleClient(
                service: "Gemini",
                baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!,
                apiKey: key,
                model: model
            )
        }
    }
}
