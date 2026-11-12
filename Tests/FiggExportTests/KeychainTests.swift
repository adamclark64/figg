import Foundation
import Security
import Testing
@testable import FiggExport

/// Stands in for the Keychain: answers with fixed results and notes the calls.
final class FakeKeychain {
    var updateResult: OSStatus = errSecSuccess
    var addResult: OSStatus = errSecSuccess
    var deleteResult: OSStatus = errSecSuccess
    var log: [String] = []
    var added: [String: Any]?

    var calls: Keychain.Calls {
        Keychain.Calls(
            update: { _, _ in self.log.append("update"); return self.updateResult },
            add: { item in self.log.append("add"); self.added = item; return self.addResult },
            delete: { _ in self.log.append("delete"); return self.deleteResult })
    }
}

@Suite struct KeychainTests {
    @Test func anExistingSecretIsUpdatedInPlace() {
        let keychain = FakeKeychain()
        #expect(Keychain.write("token", "new", using: keychain.calls))
        #expect(keychain.log == ["update"])
    }

    @Test func aFirstSaveAddsTheItem() throws {
        let keychain = FakeKeychain()
        keychain.updateResult = errSecItemNotFound
        #expect(Keychain.write("token", "new", using: keychain.calls))
        #expect(keychain.log == ["update", "add"])
        let added = try #require(keychain.added)
        #expect(added[kSecValueData as String] as? Data == Data("new".utf8))
        #expect(added[kSecAttrAccount as String] as? String == "token")
    }

    // The stored secret may be the only copy. A locked Keychain, or any
    // other refusal, must leave it where it is.
    @Test(arguments: [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable])
    func aRefusedWriteKeepsWhatIsStored(status: OSStatus) {
        let keychain = FakeKeychain()
        keychain.updateResult = status
        #expect(!Keychain.write("token", "new", using: keychain.calls))
        #expect(keychain.log == ["update"])
    }

    @Test func anEmptyValueDeletes() {
        let keychain = FakeKeychain()
        #expect(Keychain.write("token", "", using: keychain.calls))
        #expect(keychain.log == ["delete"])
        keychain.deleteResult = errSecItemNotFound
        #expect(Keychain.write("token", "", using: keychain.calls))
        keychain.deleteResult = errSecInteractionNotAllowed
        #expect(!Keychain.write("token", "", using: keychain.calls))
    }
}
