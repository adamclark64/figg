import AppKit
import SwiftUI

/// figg's look, taken from the fig logo: warm paper instead of plain white,
/// plum as the accent, olive and peach as supporting colours, warm greys.
/// `system` keeps stock macOS colours for anyone who prefers them
/// (`appearance.theme` in config.yaml).
struct Theme: Equatable {
    var canvas: Color      // main reading surface
    var sidebar: Color     // meetings list and transcript pane
    var surface: Color     // chips, inputs, cards
    var line: Color        // hairlines and chip borders
    var ink: Color         // primary text, and the user's own note lines
    var inkMuted: Color    // secondary text, and figg-added note lines
    var accent: Color      // buttons, selection, links
    var accentSoft: Color  // tinted backgrounds (recording strip, banners)
    var record: Color      // recording indicator

    /// New York (Apple's serif) for titles and note headings, like a notebook.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static let fig = Theme(
        canvas: .dynamic(light: 0xF7F4EE, dark: 0x1C1619),
        sidebar: .dynamic(light: 0xEFEAE2, dark: 0x231C20),
        surface: .dynamic(light: 0xFFFDF9, dark: 0x2C2328),
        line: .dynamic(light: 0xE2DAD2, dark: 0x3A2F35),
        ink: .dynamic(light: 0x2A1F2B, dark: 0xF1EAEE),
        inkMuted: .dynamic(light: 0x857883, dark: 0xA8999F),
        accent: .dynamic(light: 0x7B2D5E, dark: 0xE08BBD),
        accentSoft: .dynamic(light: 0xF3E4EC, dark: 0x3A2233),
        record: .dynamic(light: 0xC2413A, dark: 0xF07A70))

    static let system = Theme(
        canvas: Color(nsColor: .textBackgroundColor),
        sidebar: Color(nsColor: .windowBackgroundColor),
        surface: Color(nsColor: .controlBackgroundColor),
        line: Color(nsColor: .separatorColor),
        ink: .primary,
        inkMuted: .secondary,
        accent: .accentColor,
        accentSoft: Color.accentColor.opacity(0.12),
        record: .red)

    static func named(_ name: String) -> Theme {
        name.lowercased() == "system" ? .system : .fig
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.fig
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension Color {
    /// A colour that follows the system light/dark appearance.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Small rounded label used for the date, speakers and status under a title.
struct Chip: View {
    @Environment(\.theme) private var theme
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.callout)
            .foregroundStyle(theme.inkMuted)
            .chipBackground(theme)
    }
}

extension View {
    /// The capsule behind `Chip` and `LoadingChip`.
    func chipBackground(_ theme: Theme) -> some View {
        padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.line))
    }
}
