import AppKit
import SceneKit

/// What a 3D loader needs from its scene, so one view (`Loader3D`) can show
/// either drawing.
protocol LoaderModel: AnyObject {
    var scene: SCNScene { get }
    var cameraNode: SCNNode { get }
    /// Moves the scene to `time` seconds into its animation. Called on
    /// SceneKit's render thread. `hopScale` only matters to a loader that hops.
    func animate(at time: Double, progress: Double?, hopScale: Double)
    /// Puts the scene in its still pose, for Reduce Motion.
    func hold(progress: Double?)
}

/// Lighting and colour helpers the loader scenes share, so the fig and the
/// fig newton are lit alike.
enum LoaderStage {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Warm key, soft fill all round, plum rim from behind (figg's accent).
    /// The fill is a plain ambient light, not an environment map: SceneKit
    /// prepares those in the background, and until one is ready (seconds, at
    /// times) the loader renders a shade too dark. Less `fill` leaves the
    /// side away from the key darker, which suits a faceted shape.
    static func addLights(to scene: SCNScene, fill intensity: CGFloat = 520) {
        let fill = SCNLight()
        fill.type = .ambient
        fill.color = color(0xFFF3E0)
        fill.intensity = intensity
        let node = SCNNode()
        node.light = fill
        scene.rootNode.addChildNode(node)
        addSun(to: scene, color: 0xFFEBD2, intensity: 800, from: SCNVector3(3, 5, 4))
        addSun(to: scene, color: 0xE08BBD, intensity: 260, from: SCNVector3(-4, 2.5, -3))
    }

    private static func addSun(to scene: SCNScene, color hex: UInt32, intensity: CGFloat, from position: SCNVector3) {
        let light = SCNLight()
        light.type = .directional
        light.color = color(hex)
        light.intensity = intensity
        let node = SCNNode()
        node.light = light
        node.position = position
        node.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(node)
    }

    static func cg(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: sRGB, components: [
            CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
        ])!
    }

    static func color(_ hex: UInt32) -> NSColor {
        NSColor(cgColor: cg(hex)) ?? .white
    }

    static func bitmap(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
}
