@testable import FiggLLM
import Foundation
import Testing

@Suite struct OpenAICompatibleTests {
    typealias Provider = OpenAICompatibleProvider
    let request = LLMRequest(model: "openrouter/free", system: "sys", messages: [ChatMessage(role: .user, text: "hi")], maxTokens: 100)

    @Test func requestBodyHasNoSamplingParamsOrTokenCap() throws {
        let json = String(decoding: try Provider.body(request), as: UTF8.self)
        #expect(json == #"{"messages":[{"content":"sys","role":"system"},{"content":"hi","role":"user"}],"model":"openrouter\/free","stream":true}"#)
        #expect(!json.contains("temperature"))
        #expect(!json.contains("max_tokens"))
    }

    @Test func endpointAppendsTheRoute() throws {
        #expect(try Provider(name: "X", baseURL: "https://openrouter.ai/api/v1", apiKey: "").endpoint().absoluteString
            == "https://openrouter.ai/api/v1/chat/completions")
        #expect(try Provider(name: "X", baseURL: " http://localhost:1234/v1/ ", apiKey: "").endpoint().absoluteString
            == "http://localhost:1234/v1/chat/completions")
        #expect(throws: LLMError.self) { try Provider(name: "X", baseURL: "", apiKey: "").endpoint() }
        #expect(throws: LLMError.self) { try Provider(name: "X", baseURL: "openrouter.ai/api", apiKey: "").endpoint() }
    }

    @Test func parsesStreamLines() {
        #expect(Provider.parse(line: #"data: {"choices":[{"delta":{"content":"Hel"},"finish_reason":null}]}"#)
            == Provider.Chunk(text: "Hel"))
        #expect(Provider.parse(line: #"data:{"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
            == Provider.Chunk(finishReason: "stop"))
        #expect(Provider.parse(line: "data: [DONE]") == Provider.Chunk(done: true))
        // Thinking deltas are not part of the answer.
        #expect(Provider.parse(line: #"data: {"choices":[{"delta":{"reasoning":"hmm","content":""}}]}"#)?.text == "")
        // Keep-alive comments, other SSE fields and junk are skipped.
        #expect(Provider.parse(line: ": OPENROUTER PROCESSING") == nil)
        #expect(Provider.parse(line: "event: message") == nil)
        #expect(Provider.parse(line: "data: not json") == nil)
    }

    @Test func parsesErrorsSentMidStream() {
        let numeric = Provider.parse(line: #"data: {"error":{"code":429,"message":"slow down"},"choices":[{"delta":{"content":""},"finish_reason":"error"}]}"#)
        #expect(numeric?.error == Provider.StreamError(code: 429, message: "slow down"))
        let string = Provider.parse(line: #"data: {"error":{"code":"401","message":"no"}}"#)
        #expect(string?.error?.code == 401)
    }

    @Test func mapsErrors() {
        let p = Provider(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", apiKey: "")
        #expect(p.mapError(status: 401, message: "No auth credentials found") == .badKey(provider: "OpenRouter"))
        #expect(p.mapError(status: 404, message: "No endpoints found for x") == .badModel("No endpoints found for x"))
        #expect(p.mapError(status: 400, message: "x is not a valid model ID") == .badModel("x is not a valid model ID"))
        guard case let .other(limited) = p.mapError(status: 429, message: "free-models-per-day") else {
            Issue.record("429 should be a retryable error with the provider's detail")
            return
        }
        #expect(limited.contains("rate limiting") && limited.contains("free-models-per-day"))
        #expect(p.mapError(status: 502, message: "upstream").errorDescription == "OpenRouter error 502: upstream")
        #expect(LLMError.badKey(provider: "OpenRouter").errorDescription?.contains("Settings > AI") == true)
    }

    @Test func readsErrorBodies() {
        #expect(Provider.errorMessage(in: Data(#"{"error":{"code":401,"message":"User not found."}}"#.utf8)) == "User not found.")
        #expect(Provider.errorMessage(in: Data(#"{"error":"plain"}"#.utf8)) == "plain")
        #expect(Provider.errorMessage(in: Data("<html>bad gateway</html>".utf8)) == "<html>bad gateway</html>")
    }
}

/// Serves canned responses by host, so the whole request path (headers, body,
/// stream reading, error mapping) runs without a network.
final class StubServer: URLProtocol {
    struct Reply { var status: Int; var body: String }

    static let replies: [String: Reply] = [
        "ok.test": Reply(status: 200, body: """
        : OPENROUTER PROCESSING

        data: {"choices":[{"delta":{"role":"assistant","content":"Hel"}}]}

        data: {"choices":[{"delta":{"content":"lo"},"finish_reason":"stop"}]}

        data: [DONE]


        """),
        "denied.test": Reply(status: 401, body: #"{"error":{"code":401,"message":"No auth credentials found"}}"#),
        "silent.test": Reply(status: 200, body: "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"),
        "filtered.test": Reply(status: 200, body: "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"content_filter\"}]}\n\n"),
        "midstream.test": Reply(status: 200, body: "data: {\"choices\":[{\"delta\":{\"content\":\"par\"}}]}\n\ndata: {\"error\":{\"code\":502,\"message\":\"provider died\"}}\n\n"),
    ]

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubServer.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        // Requests echo their Authorization header back so tests can check it.
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? "none"
        let reply = Self.replies[request.url?.host ?? ""] ?? Reply(status: 500, body: "")
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream", "X-Saw-Auth": auth])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite struct OpenAICompatibleStreamTests {
    let request = LLMRequest(model: "m", system: "sys", messages: [ChatMessage(role: .user, text: "hi")])

    func provider(_ host: String, key: String = "sk-test") -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(name: "Stub", baseURL: "https://\(host)/v1", apiKey: key, session: StubServer.session)
    }

    func failure(_ host: String) async -> LLMError? {
        do {
            _ = try await provider(host).complete(request)
            return nil
        } catch {
            return error as? LLMError
        }
    }

    @Test func streamsTextInOrder() async throws {
        var deltas: [String] = []
        for try await delta in provider("ok.test").stream(request) { deltas.append(delta) }
        #expect(deltas == ["Hel", "lo"])
    }

    @Test func rejectedKeyIsReportedAsSuch() async {
        #expect(await failure("denied.test") == .badKey(provider: "Stub"))
    }

    @Test func emptyReplyIsAnErrorNotEmptyNotes() async {
        guard case let .other(message)? = await failure("silent.test") else {
            Issue.record("an empty stream should throw")
            return
        }
        #expect(message.contains("empty reply"))
    }

    @Test func contentFilterIsARefusal() async {
        #expect(await failure("filtered.test") == .refused)
    }

    @Test func errorAfterSomeTextStillFails() async {
        #expect(await failure("midstream.test") == .other("Stub error 502: provider died"))
    }
}

/// Real OpenRouter call on a free model. Run with:
///   FIGG_LIVE=1 FIGG_OPENROUTER_KEY=<key> swift test --filter LiveOpenRouterTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FIGG_LIVE"] == "1"
        && ProcessInfo.processInfo.environment["FIGG_OPENROUTER_KEY"]?.isEmpty == false))
struct LiveOpenRouterTests {
    @Test func streamsAReplyFromTheFreeRouter() async throws {
        let provider = OpenAICompatibleProvider(
            name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1",
            apiKey: ProcessInfo.processInfo.environment["FIGG_OPENROUTER_KEY"] ?? "")
        let request = LLMRequest(model: "openrouter/free", system: "Reply with exactly the word OK.",
                                 messages: [ChatMessage(role: .user, text: "Ping")])
        let text = try await provider.complete(request)
        #expect(text.uppercased().contains("OK"), "replied: \(text)")
    }
}
