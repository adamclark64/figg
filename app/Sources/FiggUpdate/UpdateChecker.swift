import FiggExport
import Foundation

/// The newest published release, reduced to what the updater needs.
public struct ReleaseInfo: Equatable, Sendable {
    /// Version without a leading v, e.g. "0.4.0".
    public var version: String
    public var dmgURL: URL
    public var dmgSize: Int
    /// Base64 Ed25519 signature over the dmg's bytes, as the version file
    /// gave it. Nil when the file had none; `UpdateVerifier` then refuses
    /// the download.
    public var signature: String?
    /// Release notes the version file carried, as given (`ReleaseNotes`
    /// picks and cuts what to show). Empty when the file had none or they
    /// could not be read; that never stops the update being offered.
    public var notes: [ReleaseNote]

    public init(version: String, dmgURL: URL, dmgSize: Int, signature: String? = nil,
                notes: [ReleaseNote] = []) {
        self.version = version
        self.dmgURL = dmgURL
        self.dmgSize = dmgSize
        self.signature = signature
        self.notes = notes
    }
}

public enum UpdateError: LocalizedError, Equatable {
    case badResponse(Int)
    case unreadableFeed
    case untrustedDownload
    case unsignedUpdate
    case badSignature

    public var errorDescription: String? {
        switch self {
        case let .badResponse(code):
            "Couldn't check for updates (HTTP \(code))."
        case .unreadableFeed:
            "Couldn't read the update information."
        case .untrustedDownload:
            "The update points somewhere other than figg's download site, so it was ignored."
        case .unsignedUpdate:
            "This update has no signature, so figg did not install it. The version you have is untouched."
        case .badSignature:
            "This update is not signed with figg's release key, so figg did not install it. The version you have is untouched."
        }
    }
}

/// Reads the version file that every release publishes to figg's public
/// download store, next to the dmg:
///
///     {"version": "0.5.1", "dmg_url": "https://<store>/releases/figg-0.5.1.dmg", "size": 22151932,
///      "signature": "<base64 Ed25519 signature over the dmg>",
///      "notes": [{"version": "0.5.1", "text": "### Bug Fixes\n\n* ..."}, ...]}
///
/// `notes` holds CHANGELOG.md sections, newest first. It is read apart from
/// the other fields and leniently: missing or malformed notes give a
/// release with no notes, never an unreadable file, so they can only add
/// to the prompt and never stop an update.
///
/// The signature is only carried from here to `UpdateInstaller`, which
/// checks it against the downloaded file (`UpdateVerifier`). A file without
/// one still parses, so the user is told why the update was refused rather
/// than never hearing of it.
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
            var signature: String?
            enum CodingKeys: String, CodingKey {
                case version, size, signature
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
        return ReleaseInfo(version: version, dmgURL: latest.dmgURL, dmgSize: latest.size,
                           signature: latest.signature, notes: Self.notes(in: data))
    }

    /// The `notes` entries of the version file that have a numeric version
    /// (a leading v dropped) and non-blank text, in file order. Decoded on
    /// its own, after the strict decode above, so nothing in `notes` can
    /// make the file unreadable: any problem with the field as a whole
    /// gives no notes, and a bad entry is skipped.
    static func notes(in data: Data) -> [ReleaseNote] {
        /// One entry, or nil when it is not `{"version": String, "text": String}`.
        /// Its init never throws, so one bad entry cannot stop the array
        /// decoding the entries after it.
        struct Entry: Decodable {
            var note: ReleaseNote?
            enum CodingKeys: String, CodingKey { case version, text }
            init(from decoder: Decoder) {
                guard let c = try? decoder.container(keyedBy: CodingKeys.self),
                      let version = try? c.decode(String.self, forKey: .version),
                      let text = try? c.decode(String.self, forKey: .text) else { return }
                note = ReleaseNote(version: version, text: text)
            }
        }
        struct NotesFeed: Decodable {
            var notes: [Entry]?
        }

        guard let entries = (try? JSONDecoder().decode(NotesFeed.self, from: data))?.notes else { return [] }
        return entries.compactMap { entry in
            guard var note = entry.note else { return nil }
            if note.version.hasPrefix("v") { note.version = String(note.version.dropFirst()) }
            guard ReleaseNotes.isNumeric(note.version),
                  !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return note
        }
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
