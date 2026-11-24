import Foundation
import Security

/// Notices when this copy of figg is signed differently from the copy that
/// last ran on this Mac.
///
/// macOS ties each permission to the signature it was granted to. After a
/// change of signer (an ad-hoc release updated to a certificate-signed one,
/// for example) the old entries stay in System Settings, switched on, and
/// macOS refuses the new copy without asking. Nothing in the app can see
/// that directly, so figg remembers its own designated requirement and, when
/// it changes, shows the Permissions screen with Fix all.
public enum SignerCheck {
    /// This process's designated requirement, e.g.
    /// `identifier "dev.adamclark.figg" and certificate leaf = H"..."`.
    public static func currentRequirement() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }

    /// `currentRequirement()` on a detached task. The Security calls read
    /// the app's code signature from disk and can be slow, so launch awaits
    /// this instead of making them on the main thread.
    public nonisolated static func currentRequirementAsync() async -> String? {
        await Task.detached(priority: .userInitiated) { currentRequirement() }.value
    }

    /// Whether to open the Permissions screen at launch: the signer is new
    /// to this Mac (or was never recorded) and something figg needs is not
    /// allowed. A new signer with everything allowed needs nothing.
    public static func shouldOpenPermissions(current: String?, stored: String?, statuses: [Permission: PermissionStatus]) -> Bool {
        guard let current, current != stored else { return false }
        let needed: [Permission] = [.microphone, .systemAudio, .accessibility]
        return needed.contains { statuses[$0] != .granted }
    }

    /// Where the last signer is kept. State, not a setting, so not config.yaml.
    public static func storeURL(in appSupport: URL) -> URL {
        appSupport.appendingPathComponent("last-signer.txt")
    }

    public static func stored(at url: URL) -> String? {
        (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func store(_ requirement: String, at url: URL) {
        try? requirement.write(to: url, atomically: true, encoding: .utf8)
    }
}
