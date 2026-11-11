import AppKit
import FiggWidget
import SceneKit

/// The 3D fig newton: a SceneKit port of the WebGL exploration
/// in `docs/design/fig-newton-3d.html`. A pillow of golden crust, extruded
/// from a cross-section with a flat bottom and domed top, whose two cut ends
/// show pale crumb around dark fig jam full of seeds.
///
/// One instance owns one scene. `apply` moves it to a `NewtonPose`; the
/// timing lives in `NewtonMotion` (FiggWidget), where it is tested.
final class FigNewtonScene {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    /// Hops, squashes and turns. The shadow stays outside it, on the ground.
    private let spin = SCNNode()
    /// The cookie itself, scaled along z as it is extruded.
    private let newton = SCNNode()
    /// Turns with the cookie so a thin slice casts a thin shadow.
    private let shadowTurn = SCNNode()
    private let shadow: SCNNode

    /// Length of a whole cookie along the extrusion axis. It is 2 wide.
    static let depth: CGFloat = 1.8
    /// A real Fig Newton is flatter than its cut shape suggests.
    static let flatten: CGFloat = 0.7
    /// Width over height of what the camera frames: the cookie at any turn,
    /// its shadow, and the top of the hop.
    static let aspect: CGFloat = 1.3

    init() {
        newton.geometry = Self.cookie()
        newton.scale = SCNVector3(1, Self.flatten, 1)
        spin.addChildNode(newton)
        scene.rootNode.addChildNode(spin)

        let blob = SCNPlane(width: 3.0, height: 2.7)
        blob.materials = [Self.shadowMaterial()]
        shadow = SCNNode(geometry: blob)
        shadow.eulerAngles.x = -.pi / 2
        shadow.position.y = -0.001
        shadow.renderingOrder = -1
        shadowTurn.addChildNode(shadow)
        scene.rootNode.addChildNode(shadowTurn)

        LoaderStage.addLights(to: scene)
        addCamera()
        apply(NewtonMotion.rest)
    }

    func apply(_ pose: NewtonPose) {
        newton.scale = SCNVector3(1, Self.flatten, CGFloat(pose.grow))
        spin.position.y = CGFloat(pose.lift)
        spin.scale = SCNVector3(CGFloat(pose.spread), CGFloat(pose.stretch), CGFloat(pose.spread))
        spin.eulerAngles.y = CGFloat(pose.yaw)
        // The shadow shrinks and fades as the cookie leaves the ground, and
        // is only as deep as the part extruded so far.
        shadowTurn.eulerAngles.y = CGFloat(pose.yaw)
        let s = 1 - pose.lift * 0.45
        shadow.scale = SCNVector3(CGFloat(s), CGFloat(s * (0.25 + 0.75 * pose.grow)), 1)
        shadow.opacity = CGFloat(0.9 - pose.lift * 0.6)
    }

    // MARK: Lights and camera

    private func addCamera() {
        let camera = SCNCamera()
        camera.fieldOfView = 23
        camera.projectionDirection = .vertical
        camera.zNear = 0.1
        camera.zFar = 50
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(3.5, 2.6, 5.4)
        cameraNode.look(at: SCNVector3(0, 0.62, 0))
        scene.rootNode.addChildNode(cameraNode)
    }

    // MARK: Shape

    /// Cross-section of the newton: flat bottom, rounded corners, domed
    /// pillow top. 2 wide and about 1 tall; `scale` shrinks it about its
    /// middle, for the crust and crumb rings on the cut end.
    static func profile(scale s: CGFloat = 1) -> CGPath {
        let cy: CGFloat = 0.5
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: (y - cy) * s + cy) }
        let r: CGFloat = 0.2
        let path = CGMutablePath()
        path.move(to: p(-1 + r, 0))
        path.addLine(to: p(1 - r, 0))
        path.addQuadCurve(to: p(1, r), control: p(1, 0))
        path.addLine(to: p(1, 0.6))
        path.addQuadCurve(to: p(0.76, 0.87), control: p(1.0, 0.82))
        path.addQuadCurve(to: p(-0.76, 0.87), control: p(0, 1.03))
        path.addQuadCurve(to: p(-1, 0.6), control: p(-1.0, 0.82))
        path.addLine(to: p(-1, r))
        path.addQuadCurve(to: p(-1 + r, 0), control: p(-1, 0))
        path.closeSubpath()
        return path
    }

    /// The rectangle of newton units the cut-end texture covers.
    static let capBounds = CGRect(x: -1.06, y: -0.06, width: 2.12, height: 1.16)

    /// Points round the profile, anticlockwise, with the outward direction
    /// at each. The directions are smoothed all the way round, so the crust
    /// shades as one surface with no crease where a curve meets a straight.
    private static func outline() -> [(point: CGPoint, normal: CGPoint)] {
        var points: [CGPoint] = []
        var last = CGPoint.zero
        profile().applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint, .addLineToPoint:
                last = e.points[0]
                points.append(last)
            case .addQuadCurveToPoint:
                let control = e.points[0], end = e.points[1]
                for i in 1...16 {
                    points.append(quadPoint(from: last, control: control, to: end, at: CGFloat(i) / 16))
                }
                last = end
            default:
                break
            }
        }
        // The path ends where it began.
        if let first = points.first, let end = points.last, hypot(first.x - end.x, first.y - end.y) < 1e-6 {
            points.removeLast()
        }
        var ring: [(point: CGPoint, normal: CGPoint)] = []
        for i in points.indices {
            let before = points[(i + points.count - 1) % points.count]
            let after = points[(i + 1) % points.count]
            let dx: CGFloat = after.x - before.x
            let dy: CGFloat = after.y - before.y
            let length: CGFloat = max(hypot(dx, dy), 1e-9)
            ring.append((points[i], CGPoint(x: dy / length, y: -dx / length)))
        }
        return ring
    }

    private static func quadPoint(from a: CGPoint, control c: CGPoint, to b: CGPoint, at t: CGFloat) -> CGPoint {
        let u: CGFloat = 1 - t
        let wa: CGFloat = u * u, wc: CGFloat = 2 * u * t, wb: CGFloat = t * t
        return CGPoint(x: wa * a.x + wc * c.x + wb * b.x, y: wa * a.y + wc * c.y + wb * b.y)
    }

    /// The cookie as one mesh: the crust as a tube round the profile with a
    /// small rounded edge at each end, and the two cut ends as flat fans.
    /// Built by hand rather than with SCNShape, which creases the crust
    /// between path elements and does not say how it maps textures onto its
    /// ends.
    private static func cookie() -> SCNGeometry {
        let ring = outline()
        let n = ring.count
        let half = depth / 2
        let bevel: CGFloat = 0.035
        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var uvs: [CGPoint] = []

        func unit(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> SCNVector3 {
            let length = sqrt(x * x + y * y + z * z)
            return SCNVector3(x / length, y / length, z / length)
        }

        // Four rings along the length: cut edge, shoulder, shoulder, cut edge.
        // Each repeats its first point at the end so the texture can wrap.
        var along: CGFloat = 0
        var distances: [CGFloat] = [0]
        for i in 0..<n {
            let a = ring[i].point, b = ring[(i + 1) % n].point
            along += hypot(b.x - a.x, b.y - a.y)
            distances.append(along)
        }
        let rings: [(z: CGFloat, inset: CGFloat, lean: CGFloat)] = [
            (-half, bevel, -1), (-half + bevel, 0, 0), (half - bevel, 0, 0), (half, bevel, 1),
        ]
        for r in rings {
            for i in 0...n {
                let (p, out) = ring[i % n]
                positions.append(SCNVector3(p.x - out.x * r.inset, p.y - out.y * r.inset, r.z))
                normals.append(unit(out.x, out.y, r.lean))
                uvs.append(CGPoint(x: distances[i] / 2, y: r.z / 2))
            }
        }
        var crust: [Int32] = []
        for r in 0..<rings.count - 1 {
            let a = r * (n + 1), b = (r + 1) * (n + 1)
            for i in 0..<n {
                let ai = Int32(a + i), aj = Int32(a + i + 1), bi = Int32(b + i), bj = Int32(b + i + 1)
                crust += [ai, aj, bj, ai, bj, bi]
            }
        }

        // The cut ends, mapped straight onto the texture drawn in the same units.
        var ends: [Int32] = []
        for facing: CGFloat in [1, -1] {
            func add(_ p: CGPoint) {
                positions.append(SCNVector3(p.x, p.y, facing * half))
                normals.append(SCNVector3(0, 0, facing))
                uvs.append(CGPoint(x: (p.x - capBounds.minX) / capBounds.width,
                                   y: 1 - (p.y - capBounds.minY) / capBounds.height))
            }
            let centre = Int32(positions.count)
            add(CGPoint(x: 0, y: 0.48))
            for (p, out) in ring { add(CGPoint(x: p.x - out.x * bevel, y: p.y - out.y * bevel)) }
            for i in 0..<n {
                let a = centre + 1 + Int32(i), b = centre + 1 + Int32((i + 1) % n)
                ends += facing > 0 ? [centre, a, b] : [centre, b, a]
            }
        }

        let geometry = SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: positions),
                SCNGeometrySource(normals: normals),
                SCNGeometrySource(textureCoordinates: uvs),
            ],
            elements: [
                SCNGeometryElement(indices: crust, primitiveType: .triangles),
                SCNGeometryElement(indices: ends, primitiveType: .triangles),
            ])
        geometry.materials = [crustMaterial(), capMaterial()]
        return geometry
    }

    // MARK: Materials

    private static func crustMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = crustImage
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        m.roughness.contents = 0.55
        m.metalness.contents = 0.0
        m.clearCoat.contents = 0.45
        m.clearCoatRoughness.contents = 0.35
        return m
    }

    private static func capMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = capImage
        m.roughness.contents = 0.8
        m.metalness.contents = 0.0
        return m
    }

    private static func shadowMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = shadowImage
        m.writesToDepthBuffer = false
        return m
    }

    // MARK: Textures, drawn once and shared by every loader

    /// The cut end: a ring of crust, crumb with pores, and a slab of jam with
    /// a wobbly edge, seeds and fibres. Drawn in newton units.
    private static let capImage: CGImage = {
        let width = 768
        let k = CGFloat(width) / capBounds.width
        let height = Int((capBounds.height * k).rounded())
        let ctx = bitmap(width: width, height: height)
        ctx.scaleBy(x: k, y: k)
        ctx.translateBy(x: -capBounds.minX, y: -capBounds.minY)
        var rng = SeededRandom(seed: 46)
        func rand() -> CGFloat { CGFloat(rng.unit()) }
        /// The exploration drew this at 1024 pixels wide; sizes below are in
        /// those pixels so the numbers match it.
        let px = capBounds.width / 1024

        // Crust to the edge, so the ring round the crumb is crust too.
        ctx.setFillColor(cg(0xB9762F))
        ctx.fill(capBounds)

        ctx.saveGState()
        ctx.addPath(profile(scale: 0.9))
        ctx.clip()
        gradient(ctx, [0xE9C58E, 0xDDB176], fromY: 1, toY: 0)
        for _ in 0..<2600 {
            let x = capBounds.minX + rand() * capBounds.width
            let y = capBounds.minY + rand() * capBounds.height
            let r = (rand() * 3 + 0.6) * px
            ctx.setFillColor(rand() < 0.5 ? cg(0xA0692D, 0.22) : cg(0xFFF0D2, 0.28))
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        }

        let jamTop: CGFloat = 0.66, jamBottom: CGFloat = 0.24, jamHalf: CGFloat = 0.8
        let jam = CGMutablePath()
        for i in 0...40 {
            let t = CGFloat(i) / 40
            let point = CGPoint(x: -jamHalf + 2 * jamHalf * t, y: jamTop + sin(t * 19) * 0.012 + (rand() - 0.5) * 0.01)
            if i == 0 { jam.move(to: point) } else { jam.addLine(to: point) }
        }
        for i in stride(from: 40, through: 0, by: -1) {
            let t = CGFloat(i) / 40
            jam.addLine(to: CGPoint(x: -jamHalf + 2 * jamHalf * t, y: jamBottom + sin(t * 23 + 1) * 0.012 + (rand() - 0.5) * 0.01))
        }
        jam.closeSubpath()
        ctx.addPath(jam)
        ctx.clip()
        gradient(ctx, [0x5A1C40, 0x6E2450, 0x4A1534], fromY: jamTop, toY: jamBottom)
        for _ in 0..<520 {
            let x = -jamHalf + rand() * 2 * jamHalf
            let y = jamBottom + rand() * (jamTop - jamBottom)
            let rx = (2.6 + rand() * 1.6) * px, ry = (1.5 + rand()) * px
            ctx.saveGState()
            ctx.translateBy(x: x, y: y)
            ctx.rotate(by: rand() * 3)
            ctx.setFillColor(rand() < 0.7 ? cg(0xE8BE96, 0.85) : cg(0xFFE1BE, 0.95))
            ctx.fillEllipse(in: CGRect(x: -rx, y: -ry, width: 2 * rx, height: 2 * ry))
            ctx.restoreGState()
        }
        ctx.setStrokeColor(cg(0x8C3C64, 0.35))
        ctx.setLineWidth(2 * px)
        for _ in 0..<70 {
            let x = -jamHalf + rand() * 2 * jamHalf
            let y = jamBottom + rand() * (jamTop - jamBottom)
            ctx.move(to: CGPoint(x: x, y: y))
            ctx.addLine(to: CGPoint(x: x + (rand() - 0.5) * 40 * px, y: y + (rand() - 0.5) * 8 * px))
            ctx.strokePath()
        }
        ctx.restoreGState()
        return ctx.makeImage()!
    }()

    /// Baked mottling for the crust.
    private static let crustImage: CGImage = {
        let side = 256
        let ctx = bitmap(width: side, height: side)
        var rng = SeededRandom(seed: 3)
        func rand() -> CGFloat { CGFloat(rng.unit()) }
        ctx.setFillColor(cg(0xC68F4C))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        for _ in 0..<1800 {
            let x = rand() * CGFloat(side), y = rand() * CGFloat(side), r = rand() * 7 + 1
            ctx.setFillColor(rand() < 0.5 ? cg(0x784619, rand() * 0.12) : cg(0xF0BE78, rand() * 0.12))
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        }
        return ctx.makeImage()!
    }()

    /// A soft blob for the ground under the cookie.
    private static let shadowImage: CGImage = {
        let side = 128
        let ctx = bitmap(width: side, height: side)
        let colors = [cg(0x000000, 0.55), cg(0x000000, 0)] as CFArray
        let fade = CGGradient(colorsSpace: sRGB, colors: colors, locations: [0, 1])!
        let centre = CGPoint(x: side / 2, y: side / 2)
        ctx.drawRadialGradient(fade, startCenter: centre, startRadius: 4, endCenter: centre, endRadius: 62,
                               options: [.drawsBeforeStartLocation])
        return ctx.makeImage()!
    }()

    // MARK: Drawing helpers

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func bitmap(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    private static func cg(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: sRGB, components: [
            CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
        ])!
    }

    /// Fills the current clip with a vertical gradient between two heights.
    private static func gradient(_ ctx: CGContext, _ stops: [UInt32], fromY: CGFloat, toY: CGFloat) {
        let fade = CGGradient(colorsSpace: sRGB, colors: stops.map { cg($0) } as CFArray, locations: nil)!
        ctx.drawLinearGradient(fade, start: CGPoint(x: 0, y: fromY), end: CGPoint(x: 0, y: toY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
}

/// SplitMix64. The textures use it instead of the system generator so every
/// launch, and every loader on screen, draws the same cookie.
private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    /// The next value in 0..<1.
    mutating func unit() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}

extension FigNewtonScene: LoaderModel {
    func animate(at time: Double, progress: Double?, hopScale: Double) {
        apply(progress.map { NewtonMotion.extruding(progress: $0, at: time) }
            ?? NewtonMotion.hop(at: time, height: NewtonMotion.hopHeight * hopScale))
    }

    func hold(progress: Double?) {
        apply(progress.map { NewtonMotion.extruding(progress: $0, at: nil) } ?? NewtonMotion.rest)
    }
}
