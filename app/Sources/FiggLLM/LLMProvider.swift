import Foundation

public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case user, assistant }
    public var role: Role
    public var text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

public struct LLMRequest: Sendable {
    public var model: String
    public var system: String
    public var messages: [ChatMessage]
    public var maxTokens: Int

    public init(model: String, system: String, messages: [ChatMessage], maxTokens: Int = 16_000) {
        self.model = model
        self.system = system
        self.messages = messages
        self.maxTokens = maxTokens
    }
}

public enum LLMError: LocalizedError, Equatable {
    /// AWS session missing or expired; the user needs to sign in again.
    case authExpired(profile: String)
    case accessDenied(String)
    case throttled
    case refused
    case badModel(String)
    /// An API-key provider (OpenRouter and the like) has no key or rejected it.
    case badKey(provider: String)
    case other(String)

    public var errorDescription: String? {
        switch self {
        case let .authExpired(profile): return "Your AWS session has expired. Sign in again (for an SSO profile: `aws sso login --profile \(profile)`)."
        case let .accessDenied(msg): return "AWS denied access to Bedrock: \(msg)"
        case .throttled: return "Bedrock is busy (throttled). Try again in a minute."
        case .refused: return "The model declined to answer this request."
        case let .badModel(msg): return "The provider rejected the model ID. Check Settings > AI. (\(msg))"
        case let .badKey(provider): return "\(provider) needs a valid API key. Add one in Settings > AI."
        case let .other(msg): return msg
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .throttled, .other: return true
        default: return false
        }
    }
}

/// Streams text from a chat model. In the app: `BedrockProvider` or
/// `OpenAICompatibleProvider`, chosen by `llm.provider` in config.yaml.
/// Fakes in tests.
public protocol LLMProvider: Sendable {
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error>
}

public extension LLMProvider {
    /// Collects the whole streamed reply.
    func complete(_ request: LLMRequest) async throws -> String {
        var out = ""
        for try await delta in stream(request) { out += delta }
        return out
    }
}
