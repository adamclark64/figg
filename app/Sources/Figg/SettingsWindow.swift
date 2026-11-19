import AppKit
import SwiftUI

/// Opens the Settings window from anywhere, including AppKit panels that have
/// no SwiftUI `openSettings` action in reach.
///
/// `NSApp.sendAction(showSettingsWindow:)` stopped working on macOS 14: the
/// SwiftUI Settings scene ignores it, so a button using it only brought figg
/// to the front. Choosing the app menu's own "Settings…" item does exactly
/// what Command-comma does on every macOS version.
@MainActor
final class SettingsWindow: ObservableObject {
    static let shared = SettingsWindow()

    enum Tab: Hashable { case permissions, ai, recording, dictation, sharing }

    /// The tab SettingsView shows. Set before opening to land on a tab.
    @Published var tab: Tab = .ai

    static func open(tab: Tab? = nil) {
        if let tab { shared.tab = tab }
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let (menu, index) = settingsItem(in: NSApp.mainMenu) {
            menu.performActionForItem(at: index)
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    /// The Command-comma item, looked up by shortcut rather than title so it
    /// is found in any language.
    private static func settingsItem(in menu: NSMenu?) -> (NSMenu, Int)? {
        guard let menu else { return nil }
        for (index, item) in menu.items.enumerated() {
            if item.keyEquivalent == ",",
               item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command {
                return (menu, index)
            }
            if let found = settingsItem(in: item.submenu) { return found }
        }
        return nil
    }
}
