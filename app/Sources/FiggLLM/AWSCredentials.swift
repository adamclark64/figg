import Foundation

public struct AWSCredentials: Sendable, Equatable {
    public var accessKeyId: String
    public var secretAccessKey: String
    public var sessionToken: String?
    public var expiration: Date?

    public init(accessKeyId: String, secretAccessKey: String, sessionToken: String? = nil, expiration: Date? = nil) {
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.expiration = expiration
    }
}

public protocol CredentialsProvider: Sendable {
    func credentials() async throws -> AWSCredentials
}

/// Gets short-lived credentials for a named profile from the AWS CLI
/// (`aws configure export-credentials`). The CLI handles credential caching
/// and refresh. Credentials stay in memory only and are never logged.
public actor AWSCLICredentialsProvider: CredentialsProvider {
    public let profile: String
    private let cliPath: String?
    private var cached: AWSCredentials?

    public init(profile: String, cliPath: String? = nil) {
        self.profile = profile
        self.cliPath = cliPath
    }

    /// GUI apps get a minimal PATH, so look in the usual install spots.
    public static func findCLI() -> String? {
        let candidates = ["/opt/homebrew/bin/aws", "/usr/local/bin/aws", "/usr/bin/aws"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func credentials() async throws -> AWSCredentials {
        if let cached, let exp = cached.expiration, exp.timeIntervalSinceNow > 300 {
            return cached
        }
        let fresh = try await export()
        cached = fresh
        return fresh
    }

    public func invalidate() { cached = nil }

    private func export() async throws -> AWSCredentials {
        guard let cli = cliPath ?? Self.findCLI() else {
            throw LLMError.other("The AWS CLI was not found. Install it with `brew install awscli`.")
        }
        let (status, out, err) = try await Self.run(cli, ["configure", "export-credentials", "--profile", profile, "--format", "process"])
        guard status == 0 else {
            if err.localizedCaseInsensitiveContains("could not be found") {
                throw LLMError.other("AWS profile '\(profile)' does not exist. Set it up with `aws configure --profile \(profile)` or `aws configure sso --profile \(profile)`.")
            }
            if err.localizedCaseInsensitiveContains("expired") || err.localizedCaseInsensitiveContains("sso")
                || err.localizedCaseInsensitiveContains("token") {
                throw LLMError.authExpired(profile: profile)
            }
            throw LLMError.other("AWS CLI failed: \(err.prefix(300))")
        }
        return try Self.parse(out)
    }

    static func parse(_ json: Data) throws -> AWSCredentials {
        struct Process: Decodable {
            var AccessKeyId: String
            var SecretAccessKey: String
            var SessionToken: String?
            var Expiration: String?
        }
        let p = try JSONDecoder().decode(Process.self, from: json)
        let exp = p.Expiration.flatMap { ISO8601DateFormatter().date(from: $0) }
        return AWSCredentials(accessKeyId: p.AccessKeyId, secretAccessKey: p.SecretAccessKey, sessionToken: p.SessionToken, expiration: exp)
    }

    static func run(_ path: String, _ args: [String]) async throws -> (Int32, Data, String) {
        try await withCheckedThrowingContinuation { cont in
            let process = Foundation.Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.terminationHandler = { p in
                let o = out.fileHandleForReading.readDataToEndOfFile()
                let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                cont.resume(returning: (p.terminationStatus, o, e))
            }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }
}
