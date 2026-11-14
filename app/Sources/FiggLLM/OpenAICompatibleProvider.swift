import Foundation

/// Any service that speaks the OpenAI chat-completions streaming API:
/// OpenRouter (including its free models), OpenAI, Groq, a local server.
/// One client covers them all, so a new service is a config entry, not code.
///
/// Like Bedrock, no temperature/top_p/top_k are sent. No `max_tokens` either:
/// figg's limits are generous ceilings sized for Claude, and many models
/// behind these APIs (free ones especially) reject a ceiling above their own
/// output cap. Leaving it out lets each model use its default.
public struct OpenAICompatibleProvider: LLMProvider {
    /// Shown in error messages, e.g. "OpenRouter".
    public let name: String
    /// API root without the route, e.g. "https://openrouter.ai/api/v1".
    public let baseURL: String
    /// Sent as a bearer token. Empty for servers that need none.
    public let apiKey: String
    let session: URLSession

    public init(name: String, baseURL: String, apiKey: String, session: URLSession = .shared) {
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    func endpoint() throws -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions"),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme), url.host != nil
        else { throw LLMError.other("\(name): the base URL in Settings > AI is not a valid http(s) address.") }
        return url
    }

    static func body(_ request: LLMRequest) throws -> Data {
        var messages: [[String: String]] = []
        if !request.system.isEmpty { messages.append(["role": "system", "content": request.system]) }
        messages += request.messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        let payload: [String: Any] = ["model": request.model, "messages": messages, "stream": true]
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ request: LLMRequest, onText: (String) -> Void) async throws {
        var http = URLRequest(url: try endpoint())
        http.httpMethod = "POST"
        http.httpBody = try Self.body(request)
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty { http.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        http.timeoutInterval = 300

        let (bytes, response) = try await session.bytes(for: http)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw LLMError.other("No response from \(name)") }
        guard status == 200 else {
            var body = Data()
            for try await b in bytes { body.append(b) }
            throw mapError(status: status, message: Self.errorMessage(in: body))
        }

        var sawText = false
        var finishReason: String?
        for try await line in bytes.lines {
            guard let chunk = Self.parse(line: line) else { continue }
            if let error = chunk.error { throw mapError(status: error.code ?? 500, message: error.message) }
            if let text = chunk.text, !text.isEmpty {
                sawText = true
                onText(text)
            }
            if let reason = chunk.finishReason { finishReason = reason }
            if chunk.done { break }
        }
        guard !sawText else { return }
        if finishReason == "content_filter" { throw LLMError.refused }
        // Free and routed models sometimes end a stream without a word.
        // Saving that as empty notes would look like figg lost the meeting.
        throw LLMError.other("\(name) returned an empty reply. Try again, or pick another model in Settings > AI.")
    }

    /// What one line of the server-sent event stream carries.
    struct Chunk: Equatable {
        var text: String?
        var finishReason: String?
        var error: StreamError?
        /// The `[DONE]` marker that ends the stream.
        var done = false
    }

    struct StreamError: Equatable {
        var code: Int?
        var message: String
    }

    /// Parses one stream line. Returns nil for anything that is not a data
    /// line: blank separators, `event:` fields, and the `: keep-alive`
    /// comments OpenRouter sends while a model warms up.
    static func parse(line: String) -> Chunk? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return Chunk(done: true) }
        guard let json = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { return nil }
        var chunk = Chunk()
        if let error = json["error"] as? [String: Any] {
            chunk.error = StreamError(code: code(error["code"]), message: error["message"] as? String ?? "Unknown error")
        }
        if let choice = (json["choices"] as? [[String: Any]])?.first {
            // Only `content` is the answer; `reasoning` deltas are thinking.
            chunk.text = (choice["delta"] as? [String: Any])?["content"] as? String
            chunk.finishReason = choice["finish_reason"] as? String
        }
        return chunk
    }

    /// Error codes arrive as numbers from some servers and strings from others.
    private static func code(_ value: Any?) -> Int? {
        (value as? Int) ?? (value as? String).flatMap(Int.init)
    }

    /// The human-readable part of an error body: `{"error":{"message":...}}`,
    /// or the raw text when the body is not that shape.
    static func errorMessage(in body: Data) -> String {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        if let error = json?["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let message = json?["error"] as? String ?? json?["message"] as? String { return message }
        return String(decoding: body, as: UTF8.self)
    }

    func mapError(status: Int, message: String) -> LLMError {
        let detail = String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        switch status {
        case 401:
            return .badKey(provider: name)
        case 404:
            return .badModel(detail)
        case 400 where detail.lowercased().contains("model"):
            return .badModel(detail)
        case 429:
            return .other("\(name) is rate limiting requests. Free models have low daily limits; try again later or pick another model. (\(detail))")
        default:
            return .other("\(name) error \(status): \(detail)")
        }
    }
}

/// Stands in when config.yaml names a provider figg cannot build, so the
/// mistake surfaces as a normal error banner on the next request.
public struct UnavailableProvider: LLMProvider {
    public let message: String

    public init(message: String) { self.message = message }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: LLMError.other(message)) }
    }
}
