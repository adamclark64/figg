import FiggWidget
import SwiftUI

/// figg's loading indicator. By default it is the fig newton, which hops
/// with a quarter turn and, given `progress` (0...1), is extruded from its
/// back until it is whole. With `appearance.loader: fig` in config.yaml it
/// is the low-poly fig from the logo instead, turning on the spot. Reduce
/// Motion holds either still.
///
/// `size` sets the scale: the fig newton is that wide, and the fig is sized
/// to sit in the same places. The layout box is fixed for a given size and
/// style, so a loader never moves the layout. The drawing is a little
/// larger than the box and overlaps what is round it: the fig by a tenth of
/// its height above and below, so it reads as big as the text beside it
/// without making the row taller, and the fig newton by its hop, above.
struct FigLoader: View {
    var progress: Double? = nil
    var size: CGFloat = 34
    /// Top of the fig newton's hop as a share of a full one (0...1), for a
    /// loader inside a small container. The fig does not hop.
    var hopScale: Double = 1
    @Environment(\.loaderStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The size the loader is drawn at.
    static func drawn(_ style: LoaderStyle, size: CGFloat) -> CGSize {
        switch style {
        case .fig:
            let height = (size * 0.62).rounded()
            return CGSize(width: (height * FigScene.aspect).rounded(), height: height)
        case .newton:
            return CGSize(width: size, height: (size / FigNewtonScene.aspect).rounded())
        }
    }

    /// The size the loader takes up in the layout.
    static func box(_ style: LoaderStyle, size: CGFloat) -> CGSize {
        let drawn = drawn(style, size: size)
        switch style {
        case .fig: return CGSize(width: drawn.width, height: (drawn.height * 0.8).rounded())
        // The resting cookie and its shadow.
        case .newton: return CGSize(width: size, height: (size * 0.46).rounded())
        }
    }

    /// How far the drawing rises above the layout box.
    static func headroom(_ style: LoaderStyle, size: CGFloat) -> CGFloat {
        let spare = drawn(style, size: size).height - box(style, size: size).height
        return (style == .fig ? spare / 2 : spare).rounded(.up)
    }

    var body: some View {
        let box = Self.box(style, size: size)
        let drawn = Self.drawn(style, size: size)
        Color.clear
            .frame(width: box.width, height: box.height)
            .overlay(alignment: style == .fig ? .center : .bottom) {
                Loader3D(style: style, progress: progress, animated: !reduceMotion, hopScale: hopScale)
                    .frame(width: drawn.width, height: drawn.height)
                    .allowsHitTesting(false)
                    // A new scene when config.yaml changes the style.
                    .id(style)
            }
            .accessibilityElement()
            .accessibilityLabel("Loading")
            .accessibilityValue(progress.map(FigLoadingLabel.percent) ?? "")
    }
}

private struct LoaderStyleKey: EnvironmentKey {
    static let defaultValue = LoaderStyle.newton
}

extension EnvironmentValues {
    /// Which loader drawing to use, from `appearance.loader` in config.yaml.
    var loaderStyle: LoaderStyle {
        get { self[LoaderStyleKey.self] }
        set { self[LoaderStyleKey.self] = newValue }
    }
}

/// A loader with a line saying what is happening, plus a percentage when the
/// progress is known. The percentage reserves the width of "100%" so the
/// text never shifts as it counts up.
struct FigLoadingLabel: View {
    @Environment(\.theme) private var theme
    let text: String
    var progress: Double? = nil
    var size: CGFloat = 34

    var body: some View {
        HStack(spacing: 6) {
            FigLoader(progress: progress, size: size)
                .accessibilityHidden(true)
            Text(text)
            if let progress {
                ZStack(alignment: .trailing) {
                    Text("100%").hidden()
                    Text(Self.percent(progress))
                }
                .monospacedDigit()
            }
        }
        .foregroundStyle(theme.inkMuted)
        .accessibilityElement(children: .combine)
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded(.down)))%"
    }
}

/// The loader on its own in an otherwise empty pane, large, with the line
/// saying what is happening under it. For "Writing notes…" before any text
/// has arrived.
struct FigLoadingPlaceholder: View {
    @Environment(\.theme) private var theme
    @Environment(\.loaderStyle) private var style
    let text: String
    var size: CGFloat = 132

    var body: some View {
        VStack(spacing: 14) {
            FigLoader(size: size)
                .padding(.top, FigLoader.headroom(style, size: size))
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.display(17, .regular))
                .foregroundStyle(theme.inkMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// `Chip` with the loader in place of the icon, for statuses that are still
/// running ("Finishing transcript…", "Writing notes…").
struct LoadingChip: View {
    @Environment(\.theme) private var theme
    @Environment(\.loaderStyle) private var style
    let text: String

    var body: some View {
        // The fig newton is about two thirds of its loader's width, so its
        // gap to the text is tighter than a chip's icon gap to look the same.
        // Its full hop would carry it 10 points above its box and out of the
        // top of the capsule, over whatever sits above the chip; at 0.4 it
        // rises 4 and stays inside. Either loader keeps the chip the size
        // of its neighbours.
        HStack(spacing: style == .newton ? 3 : 6) {
            FigLoader(size: 32, hopScale: 0.4).accessibilityHidden(true)
            Text(text)
        }
        .font(.callout)
        .foregroundStyle(theme.inkMuted)
        .chipBackground(theme)
        .accessibilityElement(children: .combine)
    }
}
