import AppKit
import FiggConfig
import FiggExport
import Foundation
import SwiftUI

/// User preferences. Everything non-secret lives in config.yaml
/// (`FiggConfig`), so it can be edited by hand or shared; Atlassian
/// credentials (email and API token) and model provider API keys live in
/// the Keychain only.
@MainActor
final class AppSettings: ObservableObject {
    let configURL: URL

    @Published var config: FiggConfig {
        didSet { if config != oldValue { save() } }
    }
    /// Set when config.yaml exists but cannot be parsed. While set, figg runs
    /// on defaults and does not overwrite the file, so a typo is never lost.
    @Published private(set) var loadError: String?

    @Published var atlassianEmail: String { didSet { Keychain.write("atlassianEmail", atlassianEmail) } }
    @Published var atlassianToken: String { didSet { Keychain.write("atlassianToken", atlassianToken) } }

    /// API keys for `llm.providers` entries, by provider id. Kept in memory
    /// so building a provider or drawing Settings does not hit the Keychain.
    @Published private(set) var llmKeys: [String: String] = [:]

    /// Read from the transcription queue's background task.
    nonisolated let keepAudio = AtomicFlag()

    init(configURL: URL = FiggConfig.defaultURL) {
        self.configURL = configURL
        config = FiggConfig()
        atlassianEmail = Keychain.read("atlassianEmail") ?? ""
        atlassianToken = Keychain.read("atlassianToken") ?? ""
        reload()
        // Write the file if it's missing, or rewrite it if a newer figg added
        // settings it doesn't list yet, so every option is visible to edit.
        let current = try? String(contentsOf: configURL, encoding: .utf8)
        if loadError == nil, current != config.yaml() { save() }
    }

    /// Re-reads config.yaml (called at launch and whenever figg comes to the front).
    func reload() {
        do {
            let loaded = try FiggConfig.load(from: configURL)
            loadError = nil
            if loaded != config { config = loaded }
        } catch {
            loadError = "\(configURL.path) could not be read, so figg is using defaults: \(error)"
        }
        keepAudio.value = config.recording.keepAudio
        loadLLMKeys()
    }

    private static func keychainAccount(provider id: String) -> String { "llmKey.\(id)" }

    /// Picks up keys for providers added to config.yaml by hand. A key the
    /// Keychain does not return is left as it was, never cleared.
    private func loadLLMKeys() {
        for p in config.llm.providers where llmKeys[p.id] == nil {
            if let key = Keychain.read(Self.keychainAccount(provider: p.id)) { llmKeys[p.id] = key }
        }
    }

    func apiKey(for providerID: String) -> String { llmKeys[providerID] ?? "" }

    /// Called only from the key field in Settings: the user typing is the
    /// one thing that may replace or remove a stored key.
    func setAPIKey(_ key: String, for providerID: String) {
        guard key != apiKey(for: providerID) else { return }
        llmKeys[providerID] = key
        Keychain.write(Self.keychainAccount(provider: providerID), key)
    }

    private func save() {
        keepAudio.value = config.recording.keepAudio
        guard loadError == nil else { return }
        do {
            try config.save(to: configURL)
        } catch {
            loadError = "Could not save \(configURL.path): \(error.localizedDescription)"
        }
    }

    func revealConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([configURL])
    }

    var atlassianConfig: AtlassianConfig? {
        guard let url = URL(string: config.sharing.atlassianSite), url.host != nil,
              !atlassianEmail.isEmpty, !atlassianToken.isEmpty else { return nil }
        return AtlassianConfig(siteURL: url, email: atlassianEmail, apiToken: atlassianToken,
                               confluenceSpaceKey: config.sharing.confluenceSpace,
                               jiraProjectKey: config.sharing.jiraProject)
    }
}

/// A Bool safe to read from any thread.
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false

    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
