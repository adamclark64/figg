import Foundation

/// Which drawing figg's loading indicator uses.
public enum LoaderStyle: String, Equatable, Sendable {
    /// The low-poly fig from the logo and the website, turning on the spot.
    case fig
    /// The hopping fig newton. Not offered in Settings: it is set by hand
    /// with `appearance.loader: newton` in config.yaml.
    case newton

    /// Anything but "newton" is the fig, so a typo can only give the default.
    public static func named(_ name: String) -> LoaderStyle {
        name.trimmingCharacters(in: .whitespaces).lowercased() == "newton" ? .newton : .fig
    }
}

/// The fig loader's motion: a steady turn about its own axis. Kept free of
/// SceneKit, like `NewtonMotion`, so it can be tested.
public enum FigSpin {
    /// Seconds for one full turn.
    public static let period: Double = 2.4
    /// The angle it holds when it is not turning (Reduce Motion), which
    /// shows the stem leaning to one side as in the logo.
    public static let restYaw: Double = 0.6

    /// The turn at `time`, in radians, always within one turn of `restYaw`
    /// so the angle stays exact after hours of uptime.
    public static func yaw(at time: Double) -> Double {
        let turns = time / period
        return restYaw + (turns - turns.rounded(.down)) * 2 * .pi
    }
}
