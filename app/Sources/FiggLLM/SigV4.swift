import CryptoKit
import Foundation

/// AWS Signature Version 4 for a single request with an in-memory body.
/// Follows https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html
public struct SigV4Signer: Sendable {
    public var region: String
    public var service: String

    public init(region: String, service: String) {
        self.region = region
        self.service = service
    }

    /// Returns `request` with `X-Amz-Date`, optional `X-Amz-Security-Token`
    /// and `Authorization` set. Signs every header already on the request
    /// plus `host`.
    public func sign(_ request: URLRequest, credentials: AWSCredentials, date: Date = Date()) -> URLRequest {
        var req = request
        let amzDate = Self.amzDateFormatter.string(from: date)
        let day = String(amzDate.prefix(8))
        req.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        if let token = credentials.sessionToken {
            req.setValue(token, forHTTPHeaderField: "X-Amz-Security-Token")
        }

        guard let url = req.url, let host = url.host else { return req }
        var headers: [String: String] = ["host": url.port.map { "\(host):\($0)" } ?? host]
        for (k, v) in req.allHTTPHeaderFields ?? [:] {
            headers[k.lowercased()] = v.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        }
        let names = headers.keys.sorted()
        let signedHeaders = names.joined(separator: ";")
        let canonicalHeaders = names.map { "\($0):\(headers[$0]!)\n" }.joined()

        let canonicalRequest = [
            req.httpMethod ?? "GET",
            Self.canonicalURI(url),
            Self.canonicalQuery(url),
            canonicalHeaders,
            signedHeaders,
            Self.hex(SHA256.hash(data: req.httpBody ?? Data())),
        ].joined(separator: "\n")

        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            Self.hex(SHA256.hash(data: Data(canonicalRequest.utf8))),
        ].joined(separator: "\n")

        let kDate = Self.hmac(key: Data("AWS4\(credentials.secretAccessKey)".utf8), day)
        let kRegion = Self.hmac(key: kDate, region)
        let kService = Self.hmac(key: kRegion, service)
        let kSigning = Self.hmac(key: kService, "aws4_request")
        let signature = Self.hex(Self.hmac(key: kSigning, stringToSign))

        req.setValue(
            "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization")
        return req
    }

    static let amzDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    /// RFC 3986 unreserved characters; everything else is percent-encoded.
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    /// Non-S3 services encode each path segment twice: the path as sent on
    /// the wire is already encoded once, and the canonical form encodes it again.
    static func canonicalURI(_ url: URL) -> String {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        if path.isEmpty { return "/" }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { encode(String($0)) }
            .joined(separator: "/")
    }

    static func canonicalQuery(_ url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let pairs: [(String, String)] = items.map { item in (encode(item.name), encode(item.value ?? "")) }
        let sorted = pairs.sorted { a, b in a.0 == b.0 ? a.1 < b.1 : a.0 < b.0 }
        return sorted.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    static func hmac(key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
