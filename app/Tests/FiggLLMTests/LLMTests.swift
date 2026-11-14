@testable import FiggLLM
import Foundation
import Testing

@Suite struct SigV4Tests {
    /// AWS SigV4 test suite case "get-vanilla".
    @Test func matchesAWSTestVector() {
        var req = URLRequest(url: URL(string: "https://example.amazonaws.com/")!)
        req.httpMethod = "GET"
        let creds = AWSCredentials(accessKeyId: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
        let date = SigV4Signer.amzDateFormatter.date(from: "20150830T123600Z")!
        let signed = SigV4Signer(region: "us-east-1", service: "service").sign(req, credentials: creds, date: date)
        #expect(signed.value(forHTTPHeaderField: "Authorization") ==
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    }

    @Test func sessionTokenIsSigned() {
        var req = URLRequest(url: URL(string: "https://bedrock-runtime.us-east-1.amazonaws.com/model/x/converse-stream")!)
        req.httpMethod = "POST"
        let creds = AWSCredentials(accessKeyId: "AK", secretAccessKey: "SK", sessionToken: "TOKEN")
        let signed = SigV4Signer(region: "us-east-1", service: "bedrock").sign(req, credentials: creds)
        #expect(signed.value(forHTTPHeaderField: "X-Amz-Security-Token") == "TOKEN")
        #expect(signed.value(forHTTPHeaderField: "Authorization")?.contains("SignedHeaders=host;x-amz-date;x-amz-security-token") == true)
    }

    @Test func canonicalURIDoubleEncodesModelIds() {
        let provider = BedrockProvider(region: "us-east-1", credentials: StaticCredentials())
        let url = provider.endpoint(model: "us.anthropic.claude-x-v1:0")
        #expect(url.absoluteString == "https://bedrock-runtime.us-east-1.amazonaws.com/model/us.anthropic.claude-x-v1%3A0/converse-stream")
        #expect(SigV4Signer.canonicalURI(url) == "/model/us.anthropic.claude-x-v1%253A0/converse-stream")
    }
}

struct StaticCredentials: CredentialsProvider {
    func credentials() async throws -> AWSCredentials { AWSCredentials(accessKeyId: "AK", secretAccessKey: "SK") }
}

@Suite struct EventStreamTests {
    static func frame(headers: [String: String], payload: String) -> Data {
        var h = Data()
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) {
            h.append(UInt8(k.utf8.count)); h.append(contentsOf: Array(k.utf8))
            h.append(7)
            h.append(UInt8(v.utf8.count >> 8)); h.append(UInt8(v.utf8.count & 0xff))
            h.append(contentsOf: Array(v.utf8))
        }
        let p = Data(payload.utf8)
        let total = 12 + h.count + p.count + 4
        func be(_ n: Int) -> [UInt8] { [UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)] }
        return Data(be(total) + be(h.count) + [0, 0, 0, 0]) + h + p + Data([0, 0, 0, 0])
    }

    @Test func decodesFramesSplitAcrossReads() throws {
        let a = Self.frame(headers: [":event-type": "contentBlockDelta", ":message-type": "event"], payload: #"{"delta":{"text":"Hel"}}"#)
        let b = Self.frame(headers: [":event-type": "contentBlockDelta", ":message-type": "event"], payload: #"{"delta":{"text":"lo"}}"#)
        var decoder = EventStreamDecoder()
        let all = a + b
        var messages: [EventStreamMessage] = []
        for i in stride(from: 0, to: all.count, by: 7) {
            decoder.append(all[i..<min(i + 7, all.count)])
            while let m = try decoder.next() { messages.append(m) }
        }
        #expect(messages.count == 2)
        #expect(messages[0].headers[":event-type"] == "contentBlockDelta")
        #expect(String(decoding: messages[1].payload, as: UTF8.self) == #"{"delta":{"text":"lo"}}"#)
    }

    @Test func requestBodyHasNoSamplingParams() throws {
        let body = try BedrockProvider.body(LLMRequest(model: "m", system: "sys", messages: [ChatMessage(role: .user, text: "hi")], maxTokens: 100))
        let json = String(decoding: body, as: UTF8.self)
        #expect(json == #"{"inferenceConfig":{"maxTokens":100},"messages":[{"content":[{"text":"hi"}],"role":"user"}],"system":[{"text":"sys"}]}"#)
        #expect(!json.contains("temperature"))
    }

    @Test func parsesCLICredentials() throws {
        let json = Data(#"{"Version":1,"AccessKeyId":"AK","SecretAccessKey":"SK","SessionToken":"T","Expiration":"2030-01-01T00:00:00+00:00"}"#.utf8)
        let c = try AWSCLICredentialsProvider.parse(json)
        #expect(c.accessKeyId == "AK" && c.sessionToken == "T")
        #expect(c.expiration != nil)
    }
}

/// Real Bedrock call through figg's own signer and stream decoder. Costs a
/// fraction of a cent. Needs working credentials for the profile. Run with:
///   FIGG_LIVE=1 FIGG_PROFILE=<name> swift test --filter LiveBedrockTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FIGG_LIVE"] == "1"))
struct LiveBedrockTests {
    let profile = ProcessInfo.processInfo.environment["FIGG_PROFILE"] ?? "default"

    @Test(arguments: ["us.anthropic.claude-haiku-5-5", "us.anthropic.claude-sonnet-5-5"])
    func streamsAReply(model: String) async throws {
        let provider = BedrockProvider(region: "us-east-1", credentials: AWSCLICredentialsProvider(profile: profile))
        let request = LLMRequest(model: model, system: "Reply with exactly the word OK.",
                                 messages: [ChatMessage(role: .user, text: "Ping")], maxTokens: 50)
        var deltas = 0
        var text = ""
        for try await delta in provider.stream(request) {
            deltas += 1
            text += delta
        }
        #expect(text.uppercased().contains("OK"), "\(model) replied: \(text)")
        #expect(deltas >= 1)
    }
}
