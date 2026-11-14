import CryptoKit
import FiggUpdate
import Foundation
import Testing

/// A throwaway release key and a file to sign with it. Nothing here is the
/// real key: each test makes its own pair in memory.
struct SigningFixture {
    let key = Curve25519.Signing.PrivateKey()
    let file: URL

    init(contents: Data = Data("a pretend dmg".utf8)) throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("figg-verifier-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("figg.dmg")
        try contents.write(to: file)
    }

    var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

    /// What the publish step would put in latest.json for the file as it is now.
    func signature() throws -> String {
        try key.signature(for: Data(contentsOf: file)).base64EncodedString()
    }
}

@Suite struct UpdateVerifierTests {
    @Test func aFileSignedWithTheReleaseKeyIsAccepted() throws {
        let fixture = try SigningFixture()
        let verifier = UpdateVerifier(publicKeys: [fixture.publicKey])
        try verifier.verify(dmg: fixture.file, signature: fixture.signature())
    }

    @Test func aFileChangedAfterSigningIsRefused() throws {
        let fixture = try SigningFixture()
        let signature = try fixture.signature()
        // One byte appended is enough.
        try (Data(contentsOf: fixture.file) + Data([0])).write(to: fixture.file)
        let verifier = UpdateVerifier(publicKeys: [fixture.publicKey])
        #expect(throws: UpdateError.badSignature) {
            try verifier.verify(dmg: fixture.file, signature: signature)
        }
    }

    @Test func aMissingSignatureIsRefused() throws {
        let fixture = try SigningFixture()
        let verifier = UpdateVerifier(publicKeys: [fixture.publicKey])
        for signature in [nil, ""] as [String?] {
            #expect(throws: UpdateError.unsignedUpdate) {
                try verifier.verify(dmg: fixture.file, signature: signature)
            }
        }
    }

    @Test func aSignatureFromAnotherKeyIsRefused() throws {
        let fixture = try SigningFixture()
        let stranger = Curve25519.Signing.PrivateKey()
        let signature = try stranger.signature(for: Data(contentsOf: fixture.file)).base64EncodedString()
        let verifier = UpdateVerifier(publicKeys: [fixture.publicKey])
        #expect(throws: UpdateError.badSignature) {
            try verifier.verify(dmg: fixture.file, signature: signature)
        }
    }

    @Test func aMalformedSignatureIsRefused() throws {
        let fixture = try SigningFixture()
        let good = try fixture.signature()
        let verifier = UpdateVerifier(publicKeys: [fixture.publicKey])
        let malformed = [
            "not base64 at all!",
            // Valid base64, wrong length.
            Data("short".utf8).base64EncodedString(),
            String(good.dropLast(4)),
            good + good,
            // The right length, but not a signature.
            Data(repeating: 0, count: 64).base64EncodedString(),
        ]
        for signature in malformed {
            #expect(throws: UpdateError.badSignature) {
                try verifier.verify(dmg: fixture.file, signature: signature)
            }
        }
    }

    @Test func withNoTrustedKeyEverythingIsRefused() throws {
        // Fail closed: an empty or unreadable key list never means "trust all".
        let fixture = try SigningFixture()
        let signature = try fixture.signature()
        for keys in [[], ["garbage"], [Data("too short".utf8).base64EncodedString()]] {
            #expect(throws: UpdateError.badSignature) {
                try UpdateVerifier(publicKeys: keys).verify(dmg: fixture.file, signature: signature)
            }
        }
    }

    @Test func anyOneOfSeveralTrustedKeysWillDo() throws {
        // How a key is replaced: for one release the app trusts old and new.
        let fixture = try SigningFixture()
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let verifier = UpdateVerifier(publicKeys: [other, fixture.publicKey])
        try verifier.verify(dmg: fixture.file, signature: fixture.signature())
    }

    @Test func aFileThatCannotBeReadIsRefused() throws {
        let fixture = try SigningFixture()
        let signature = try fixture.signature()
        try FileManager.default.removeItem(at: fixture.file)
        #expect(throws: (any Error).self) {
            try UpdateVerifier(publicKeys: [fixture.publicKey]).verify(dmg: fixture.file, signature: signature)
        }
    }

    @Test func theAppShipsWithAUsableReleaseKey() throws {
        // An empty or mistyped list would make every installed copy refuse
        // every update, with no way to send it a fix.
        #expect(!UpdateVerifier.releaseKeys.isEmpty)
        for key in UpdateVerifier.releaseKeys {
            let raw = try #require(Data(base64Encoded: key))
            #expect(throws: Never.self) { try Curve25519.Signing.PublicKey(rawRepresentation: raw) }
        }
    }

    @Test func acceptsASignatureMadeOutsideCryptoKit() throws {
        // RFC 8032 section 7.1, test 2: a published Ed25519 key, one-byte
        // message and signature. The release job signs with Node, not
        // CryptoKit, so the check must be plain Ed25519 over the raw bytes.
        func bytes(_ hex: String) -> Data {
            var data = Data()
            var rest = Substring(hex)
            while !rest.isEmpty {
                data.append(UInt8(rest.prefix(2), radix: 16)!)
                rest = rest.dropFirst(2)
            }
            return data
        }
        let publicKey = bytes("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")
        let signature = bytes(
            "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da"
                + "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00")
        let fixture = try SigningFixture(contents: Data([0x72]))
        let verifier = UpdateVerifier(publicKeys: [publicKey.base64EncodedString()])
        try verifier.verify(dmg: fixture.file, signature: signature.base64EncodedString())
    }
}
