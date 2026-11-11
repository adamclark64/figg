import Foundation

/// Claude on AWS Bedrock via the Converse streaming API, signed with SigV4.
/// No temperature/top_p/top_k and no thinking config are sent; current Claude
/// models reject sampling parameters and run adaptive thinking by default.
public struct BedrockProvider: LLMProvider {
    public let region: String
    public let credentials: CredentialsProvider
    let session: URLSession

    public init(region: String, credentials: CredentialsProvider, session: URLSession = .shared) {
        self.region = region
        self.credentials = credentials
        self.session = session
    }

    func endpoint(model: String) -> URL {
        // Model IDs can contain ':' (e.g. "...-v1:0"), which must be percent-encoded in the path.
        let id = model.addingPercentEncoding(withAllowedCharacters: SigV4Signer.unreserved) ?? model
        var components = URLComponents()
        components.scheme = "https"
        components.host = "bedrock-runtime.\(region).amazonaws.com"
        components.percentEncodedPath = "/model/\(id)/converse-stream"
        return components.url!
    }

    static func body(_ request: LLMRequest) throws -> Data {
        let payload: [String: Any] = [
            "system": [["text": request.system]],
            "messages": request.messages.map { ["role": $0.role.rawValue, "content": [["text": $0.text]]] },
            "inferenceConfig": ["maxTokens": request.maxTokens],
        ]
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
        let creds = try await credentials.credentials()
        var http = URLRequest(url: endpoint(model: request.model))
        http.httpMethod = "POST"
        http.httpBody = try Self.body(request)
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("application/vnd.amazon.eventstream", forHTTPHeaderField: "Accept")
        http.timeoutInterval = 300
        let signed = SigV4Signer(region: region, service: "bedrock").sign(http, credentials: creds)

        let (bytes, response) = try await session.bytes(for: signed)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw LLMError.other("No response from Bedrock") }
        guard status == 200 else {
            var body = Data()
            for try await b in bytes { body.append(b) }
            let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-amzn-ErrorType") ?? ""
            throw await mapError(type: type, status: status, body: body)
        }

        var decoder = EventStreamDecoder()
        var sawText = false
        var stopReason: String?
        for try await byte in bytes {
            decoder.append(Data([byte]))
            while let message = try decoder.next() {
                if message.headers[":message-type"] == "exception" {
                    throw await mapError(type: message.headers[":exception-type"] ?? "", status: 200, body: message.payload)
                }
                let json = (try? JSONSerialization.jsonObject(with: message.payload)) as? [String: Any]
                switch message.headers[":event-type"] {
                case "contentBlockDelta":
                    if let delta = json?["delta"] as? [String: Any], let text = delta["text"] as? String {
                        sawText = true
                        onText(text)
                    }
                case "messageStop":
                    stopReason = json?["stopReason"] as? String
                default:
                    break
                }
            }
        }
        if !sawText, let stopReason, !["end_turn", "max_tokens", "stop_sequence"].contains(stopReason) {
            throw LLMError.refused
        }
    }

    private func mapError(type: String, status: Int, body: Data) async -> LLMError {
        let message = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["message"] as? String
            ?? String(decoding: body, as: UTF8.self)
        let kind = type.split(separator: ":").first.map(String.init) ?? type
        switch kind.lowercased() {
        case let k where k.contains("expiredtoken") || k.contains("unrecognizedclient") || k.contains("invalidsignature"):
            if let cli = credentials as? AWSCLICredentialsProvider {
                await cli.invalidate()
                return .authExpired(profile: cli.profile)
            }
            return .authExpired(profile: "default")
        case let k where k.contains("accessdenied"):
            return .accessDenied(message)
        case let k where k.contains("throttling") || k.contains("serviceunavailable") || k.contains("modelnotready"):
            return .throttled
        case let k where k.contains("validation") && message.lowercased().contains("model"):
            return .badModel(message)
        case let k where k.contains("resourcenotfound"):
            return .badModel(message)
        default:
            return .other("Bedrock error \(status) \(kind): \(message.prefix(300))")
        }
    }
}
