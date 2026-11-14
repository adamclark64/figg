import Foundation

/// Where the 3D fig newton loader is at one moment. Lengths are in newton
/// units: the cookie is 2 wide and sits on y = 0.
public struct NewtonPose: Equatable, Sendable {
    /// Height off the ground.
    public var lift: Double
    /// Vertical scale: under 1 is a squash, over 1 a stretch.
    public var stretch: Double
    /// Horizontal scale, the opposite of `stretch` so the cookie keeps its volume.
    public var spread: Double
    /// Turn about the vertical axis, in radians.
    public var yaw: Double
    /// Length along the extrusion axis, 0...1 of a whole cookie.
    public var grow: Double

    public init(lift: Double, stretch: Double, spread: Double, yaw: Double, grow: Double) {
        self.lift = lift
        self.stretch = stretch
        self.spread = spread
        self.yaw = yaw
        self.grow = grow
    }
}

/// The loader's motion, ported from the WebGL exploration in
/// `docs/design/fig-newton-3d.html` and kept free of SceneKit so the timing
/// can be tested.
public enum NewtonMotion {
    /// Seconds for one hop.
    public static let period: Double = 1.5
    /// The three-quarter view the cookie rests at.
    public static let restYaw: Double = -0.55
    /// Top of a full hop.
    public static let hopHeight: Double = 0.75
    /// The thinnest slice shown for known progress, so 0% is not empty.
    public static let minimumGrow: Double = 0.03

    /// Standing still and whole: Reduce Motion, and the start of every hop.
    public static let rest = NewtonPose(lift: 0, stretch: 1, spread: 1, yaw: restYaw, grow: 1)

    /// Unknown length: crouch, hop with a quarter turn in the air, land with
    /// a squash. Every other hop shows the cut end and its jam. `height` is
    /// the top of the hop; a loader with little room above it asks for less.
    public static func hop(at time: Double, height: Double = hopHeight) -> NewtonPose {
        let cycles = (time / period).rounded(.down)
        let t = time / period - cycles
        // Four quarter turns are a full one, so only the remainder matters.
        // Keeping it small also keeps the angle exact after hours of uptime.
        let turns = cycles - 4 * (cycles / 4).rounded(.down)
        let quarter = Double.pi / 2
        var pose = rest
        if t < 0.18 {
            let k = sin(t / 0.18 * .pi)
            pose.stretch = 1 - 0.14 * k
            pose.spread = 1 + 0.07 * k
            pose.yaw += turns * quarter
        } else if t < 0.78 {
            let a = (t - 0.18) / 0.6
            let arc = sin(a * .pi)
            pose.lift = arc * max(height, 0)
            pose.stretch = 1 + 0.08 * arc
            pose.spread = 1 - 0.04 * arc
            pose.yaw += (turns + ease(a)) * quarter
        } else {
            let k = sin((t - 0.78) / 0.22 * .pi)
            pose.stretch = 1 - 0.1 * k
            pose.spread = 1 + 0.05 * k
            pose.yaw += (turns + 1) * quarter
        }
        return pose
    }

    /// Known progress: the cookie is extruded from its back, the way the real
    /// ones are made, and 100% is a whole cookie. With a `time` it sways a
    /// little so it does not look frozen between updates; nil holds it still.
    public static func extruding(progress: Double, at time: Double?) -> NewtonPose {
        var pose = rest
        pose.grow = max(minimumGrow, min(max(progress, 0), 1))
        if let time { pose.yaw += sin(time * 0.6) * 0.12 }
        return pose
    }

    /// Cubic ease in and out.
    static func ease(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}
