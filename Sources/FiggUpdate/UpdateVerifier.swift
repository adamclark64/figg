import CryptoKit
import Foundation

/// Decides whether a downloaded dmg is one that figg's release job published.
///
/// The release job signs the dmg's bytes with an Ed25519 key that only it
/// holds (the `FIGG_UPDATE_SIGNING_KEY` secret) and writes the signature
/// into latest.json. The public half is compiled in below. So the download
/// store is no longer trusted on its own: whoever can write to it can
/// replace the dmg or the version file, but cannot make a signature this
/// accepts. See `docs/release-signing.md`.
///
/// It fails closed. No signature, an unreadable one, or one made with any
/// other key all mean the dmg is refused; nothing here falls back to
/// "install anyway".
public struct UpdateVerifier: Sendable {
    /// The keys a release may be signed with: base64 of each raw 32-byte
    /// Ed25519 public key. More than one only while a key is being replaced
    /// (the release that introduces the new key is signed with the old one).
    /// `scripts/publish-dmg-blob.mjs` reads this file and refuses to publish
    /// with a key that is not listed here.
    public static let releaseKeys: [String] = []

    /// Raw public keys. Kept as bytes so the type stays Sendable.
    private let keys: [Data]

    /// Entries that are not base64 of 32 bytes are dropped, which can only
    /// make the verifier stricter.
    public init(publicKeys: [String] = UpdateVerifier.releaseKeys) {
        keys = publicKeys.compactMap { Data(base64Encoded: $0) }.filter { $0.count == 32 }
    }

    /// Throws unless `signature` (base64, as latest.json carries it) is a
    /// valid signature over the file's bytes by one of the trusted keys.
    public func verify(dmg: URL, signature: String?) throws {
        guard let signature, !signature.isEmpty else { throw UpdateError.unsignedUpdate }
        // An Ed25519 signature is exactly 64 bytes.
        guard let raw = Data(base64Encoded: signature), raw.count == 64 else {
            throw UpdateError.badSignature
        }
        // Mapped, not read: a dmg is tens of megabytes.
        let bytes = try Data(contentsOf: dmg, options: .mappedIfSafe)
        let trusted = keys.contains { key in
            guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { return false }
            return publicKey.isValidSignature(raw, for: bytes)
        }
        guard trusted else { throw UpdateError.badSignature }
    }
}
