import FiggExport
import Foundation

/// The newest published release, reduced to what the updater needs.
public struct ReleaseInfo: Equatable, Sendable {
    /// Version without a leading v, e.g. "0.4.0".
    public var version: String
    public var dmgURL: URL
    public var dmgSize: Int

    public init(version: String, dmgURL: URL, dmgSize: Int) {
        self.version = version
        self.dmgURL = dmgURL
        self.dmgSize = dmgSize
    }
}

public enum UpdateError: LocalizedError, Equatable {
    case badResponse(Int)
    case unreadableFeed
    case untrustedDownload

    public var errorDescription: String? {
        switch self {
        case let .badResponse(code):
            "Couldn't check for updates (HTTP \(code))."
        case .unreadableFeed:
            "Couldn't read the update information."
        case .untrustedDownload:
            "The update points somewhere other than figg's download site, so it was ignored."
        }
    }
}

/// Reads the version file that every release publishes to figg's public
/// download store, next to the dmg:
///
///     {"version": "0.5.1", "dmg_url": "https://<store>/releases/figg-0.5.1.dmg", "size": 22151932}
///
/// A static file, not the GitHub Releases API, so the check never depends on
/// GitHub's anonymous rate limits. It is anonymous: no token exists anywhere
/// (hard rule 2), and nothing is sent but the request.
public struct UpdateChecker: Sendable {
    /// The store the website's download button also points at.
    public static let defaultFeed = URL(string: "https://3gwgc5ir6t6yxpzh.public.blob.vercel-storage.com/latest.json")!

    public var feed: URL
    let http: any HTTPClient

    public init(feed: URL = UpdateChecker.defaultFeed, http: any HTTPClient = URLSessionHTTPClient()) {
        self.feed = feed
        self.http = http
    }

    public func latest() async throws -> ReleaseInfo {
        var request = URLRequest(url: feed)
        // A cached copy would hide a release published since the last check.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.send(request)
        guard response.statusCode == 200 else { throw UpdateError.badResponse(response.statusCode) }

        struct Feed: Decodable {
            var version: String
            var dmgURL: URL
            var size: Int
            enum CodingKeys: String, CodingKey {
                case version, size
                case dmgURL = "dmg_url"
            }
        }

        guard let latest = try? JSONDecoder().decode(Feed.self, from: data) else {
            throw UpdateError.unreadableFeed
        }
        // The dmg is installed over the running app, so it may only come
        // from the store the version file itself came from, over https.
        guard latest.dmgURL.scheme == "https", let host = latest.dmgURL.host, host == feed.host else {
            throw UpdateError.untrustedDownload
        }
        let version = latest.version.hasPrefix("v") ? String(latest.version.dropFirst()) : latest.version
        return ReleaseInfo(version: version, dmgURL: latest.dmgURL, dmgSize: latest.size)
    }

    /// Strict numeric dot-component compare. Anything non-numeric (prerelease
    /// tags, dev builds with odd strings) is never "newer", so a broken
    /// version can only suppress the banner, not nag with one.
    public static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ s: String) -> [Int]? {
            let p = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard !p.isEmpty, !p.contains(nil) else { return nil }
            return p.compactMap { $0 }
        }
        guard let r = parts(remote), let l = parts(local) else { return false }
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0
            let b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}
