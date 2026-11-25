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

    /// The didSets write the Keychain only for a change the user made: while
    /// `loadSecrets` applies what it read, `loadingSecrets` is set, so a
    /// loaded value is never written back (and an empty one never deletes).
    @Published var atlassianEmail: String = "" {
        didSet { if !loadingSecrets { Keychain.write("atlassianEmail", atlassianEmail) } }
    }
    @Published var atlassianToken: String = "" {
        didSet { if !loadingSecrets { Keychain.write("atlassianToken", atlassianToken) } }
    }

    /// False until the first `loadSecrets` finishes. Settings disables the
    /// email, token and API key fields until then, so nothing the user types
    /// can race a Keychain read that is still in flight.
    @Published private(set) var secretsLoaded = false

    /// Set while `loadSecrets` applies values it read, so the didSet writers skip them.
    private var loadingSecrets = false

    /// API keys for `llm.providers` entries, by provider id. Kept in memory
    /// so building a provider or drawing Settings does not hit the Keychain.
    @Published private(set) var llmKeys: [String: String] = [:]

    /// Read from the transcription queue's background task.
    nonisolated let keepAudio = AtomicFlag()
    /// `transcription.skip_mic_when_muted`, read off the main actor by the transcription queue.
    nonisolated let skipMicWhenMuted = AtomicFlag()

    init(configURL: URL = FiggConfig.defaultURL) {
        self.configURL = configURL
        config = FiggConfig()
        reload()
        // Write the file if it's missing, or rewrite it if a newer figg added
        // settings it doesn't list yet, so every option is visible to edit.
        let current = try? String(contentsOf: configURL, encoding: .utf8)
        if loadError == nil, current != config.yaml() { save() }
        // init runs on the main thread before any window exists, and a
        // Keychain read can block on securityd or wait on an access prompt,
        // so secrets are not read here: `loadSecrets()` is the first launch
        // step (`AppModel.finishLaunch`), after the window has drawn.
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
        skipMicWhenMuted.value = config.transcription.skipMicWhenMuted
        // Runs on every activation, so it never reads the Keychain inline:
        // keys for providers added to config.yaml by hand load in the background.
        if secretsLoaded, config.llm.providers.contains(where: { llmKeys[$0.id] == nil }) {
            Task { await loadSecrets() }
        }
    }

    private nonisolated static func keychainAccount(provider id: String) -> String { "llmKey.\(id)" }

    /// Reads the Atlassian items (on the first load only) and the key of
    /// every provider in `config.llm.providers` that is not loaded yet, off
    /// the main thread, then applies them here without running the Keychain
    /// writers. A value the Keychain does not return (missing, locked,
    /// refused) is left as it is, never cleared, so a late, empty or failed
    /// read cannot overwrite a stored item.
    func loadSecrets() async {
        let readAtlassian = !secretsLoaded
        let providerIDs = config.llm.providers.map(\.id).filter { llmKeys[$0] == nil }
        let read = await Task.detached(priority: .userInitiated) { () -> LoadedSecrets in
            var out = LoadedSecrets()
            if readAtlassian {
                out.email = Keychain.read("atlassianEmail")
                out.token = Keychain.read("atlassianToken")
            }
            for id in providerIDs {
                if let key = Keychain.read(AppSettings.keychainAccount(provider: id)) { out.keys[id] = key }
            }
            return out
        }.value

        loadingSecrets = true
        defer { loadingSecrets = false }
        if readAtlassian, !secretsLoaded {
            if let email = read.email { atlassianEmail = email }
            if let token = read.token { atlassianToken = token }
        }
        // A key set by the user while the read was in flight wins.
        for (id, key) in read.keys where llmKeys[id] == nil { llmKeys[id] = key }
        secretsLoaded = true
    }

    /// What one background Keychain read returned; nil means not read or not found.
    private struct LoadedSecrets: Sendable {
        var email: String?
        var token: String?
        var keys: [String: String] = [:]
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
        skipMicWhenMuted.value = config.transcription.skipMicWhenMuted
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
