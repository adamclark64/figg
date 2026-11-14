import AppKit
import FiggWidget
import SceneKit
import simd

/// The 3D fig: a SceneKit port of the fig on the website
/// (`makeFig` in `site/index.html`). A low-poly body, lathed from a ten-point
/// profile with ten sides, whose facets are banded from plum at the base to
/// green at the neck like the logo, with a bent stem on top.
///
/// As a loader it turns on the spot; the stem leaning to one side is what
/// shows the turn. One instance owns one scene.
final class FigScene: LoaderModel {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    /// Turns about the vertical axis through the fig's belly.
    private let pivot = SCNNode()

    /// Height of the body, base to neck. It is 1.64 across at its widest.
    static let height: CGFloat = 1.75
    /// Width over height of what the camera frames: the fig and its stem at
    /// any turn.
    static let aspect: CGFloat = 0.8

    init() {
        let inner = SCNNode()
        inner.addChildNode(SCNNode(geometry: Self.body()))
        Self.addStem(to: inner)
        inner.position.y = -Self.height * 0.45
        pivot.addChildNode(inner)
        scene.rootNode.addChildNode(pivot)

        LoaderStage.addLights(to: scene, fill: 300)
        let camera = SCNCamera()
        camera.fieldOfView = 22.5
        camera.projectionDirection = .vertical
        camera.zNear = 0.1
        camera.zFar = 50
        cameraNode.camera = camera
        // A little above, so the top facets and the stem's bend both show.
        cameraNode.position = SCNVector3(0, 1.1, 6.2)
        cameraNode.look(at: SCNVector3(0, 0.29, 0))
        scene.rootNode.addChildNode(cameraNode)
        hold(progress: nil)
    }

    /// The fig has no drawing for known progress: it turns either way and
    /// the label beside it shows the percentage.
    func animate(at time: Double, progress: Double?, hopScale: Double) {
        pivot.eulerAngles.y = CGFloat(FigSpin.yaw(at: time))
    }

    func hold(progress: Double?) {
        pivot.eulerAngles.y = CGFloat(FigSpin.restYaw)
    }

    // MARK: Body

    /// Radius and height of each ring, base first.
    private static let profile: [(r: Float, y: Float)] = [
        (0.0, 0.0), (0.42, 0.04), (0.7, 0.2), (0.82, 0.44), (0.8, 0.66),
        (0.66, 0.9), (0.46, 1.12), (0.28, 1.34), (0.16, 1.54), (0.1, Float(height)),
    ]
    private static let sides = 10

    /// The colour bands, as height (0 base, 1 neck) and colour.
    private static let bands: [(t: Float, hex: UInt32)] = [
        (0.0, 0x5A2456), (0.16, 0x9A3472), (0.3, 0xCF5A80), (0.44, 0xE88A84),
        (0.58, 0xECA06A), (0.7, 0xF7CC78), (0.82, 0xDCD468), (1.0, 0xA6C246),
    ]

    /// The body as flat facets, each one colour. Every triangle has its own
    /// three vertices and its own normal, which is what makes it low-poly,
    /// and its colour comes from a one-pixel-per-facet strip: SceneKit does
    /// not say which colour space it reads vertex colours in, and it does
    /// for images.
    private static func body() -> SCNGeometry {
        func point(_ ring: Int, _ side: Int) -> SIMD3<Float> {
            let angle = Float(side % sides) / Float(sides) * 2 * .pi
            let (r, y) = profile[ring]
            return SIMD3(r * sin(angle), y, r * cos(angle))
        }
        var corners: [[SIMD3<Float>]] = []
        for side in 0..<sides {
            for ring in 0..<profile.count - 1 {
                let a = point(ring, side), b = point(ring, side + 1)
                let c = point(ring + 1, side + 1), d = point(ring + 1, side)
                corners.append([a, b, d])
                corners.append([b, c, d])
            }
            // Close the neck under the stem.
            let top = profile.count - 1
            corners.append([SIMD3(0, Float(height), 0), point(top, side), point(top, side + 1)])
        }

        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var facets: [CGColor] = []
        var facetOfVertex: [Int] = []
        for var triangle in corners {
            var normal = simd_cross(triangle[1] - triangle[0], triangle[2] - triangle[0])
            // The ring at the base is a single point, so one triangle of
            // each quad there has no area.
            guard simd_length(normal) > 1e-6 else { continue }
            normal = simd_normalize(normal)
            // Facets face away from the axis (or straight up, on the neck).
            let centre = (triangle[0] + triangle[1] + triangle[2]) / 3
            let outward = simd_dot(normal, SIMD3(centre.x, 0, centre.z))
            if outward < 0 || (abs(outward) < 1e-6 && normal.y < 0) {
                triangle.swapAt(1, 2)
                normal = -normal
            }
            let jitter = (sin(Float(facets.count) * 12.9898 + centre.x * 78.233) * 43758.5453)
                .truncatingRemainder(dividingBy: 1)
            facets.append(bandColour(at: centre.y / Float(height), lift: jitter * 0.04))
            for p in triangle {
                positions.append(SCNVector3(CGFloat(p.x), CGFloat(p.y), CGFloat(p.z)))
                normals.append(SCNVector3(CGFloat(normal.x), CGFloat(normal.y), CGFloat(normal.z)))
                facetOfVertex.append(facets.count - 1)
            }
        }

        let strip = LoaderStage.bitmap(width: facets.count, height: 1)
        for (i, colour) in facets.enumerated() {
            strip.setFillColor(colour)
            strip.fill(CGRect(x: i, y: 0, width: 1, height: 1))
        }
        let uvs = facetOfVertex.map { CGPoint(x: (CGFloat($0) + 0.5) / CGFloat(facets.count), y: 0.5) }

        let geometry = SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: positions),
                SCNGeometrySource(normals: normals),
                SCNGeometrySource(textureCoordinates: uvs),
            ],
            elements: [SCNGeometryElement(indices: Array(0..<Int32(positions.count)), primitiveType: .triangles)])
        let skin = SCNMaterial()
        skin.lightingModel = .physicallyBased
        skin.diffuse.contents = strip.makeImage()!
        // One pixel is one facet: no blending into the neighbours.
        skin.diffuse.magnificationFilter = .nearest
        skin.diffuse.minificationFilter = .nearest
        skin.diffuse.mipFilter = .none
        skin.roughness.contents = 0.7
        skin.metalness.contents = 0.0
        geometry.materials = [skin]
        return geometry
    }

    /// The band colour at a height, blended in linear light as the website
    /// does, then lightened or darkened a touch so no two facets match.
    private static func bandColour(at height: Float, lift: Float) -> CGColor {
        func linear(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func encoded(_ c: Float) -> Float { c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055 }
        func rgb(_ hex: UInt32) -> SIMD3<Float> {
            SIMD3(linear(Float((hex >> 16) & 0xFF) / 255), linear(Float((hex >> 8) & 0xFF) / 255), linear(Float(hex & 0xFF) / 255))
        }
        let t = min(max(height, 0), 1)
        var mixed = rgb(bands[bands.count - 1].hex)
        for i in 1..<bands.count where t <= bands[i].t {
            let (t0, c0) = bands[i - 1], (t1, c1) = bands[i]
            mixed = simd_mix(rgb(c0), rgb(c1), SIMD3(repeating: (t - t0) / (t1 - t0)))
            break
        }
        let out = [mixed.x, mixed.y, mixed.z].map { CGFloat(min(max(encoded($0) + lift, 0), 1)) }
        return CGColor(colorSpace: LoaderStage.sRGB, components: out + [1])!
    }

    // MARK: Stem

    /// A short green stem that bends to one side, with a brown cut tip.
    private static func addStem(to parent: SCNNode) {
        let h = Float(height)
        let bend: [SIMD3<Float>] = [
            SIMD3(0, h - 0.08, 0), SIMD3(0.02, h + 0.12, 0), SIMD3(0.1, h + 0.3, 0), SIMD3(0.24, h + 0.4, 0),
        ]
        let path = smooth(bend, steps: 2)
        for (from, to) in zip(path, path.dropFirst()) {
            // A hair long, so the joints between pieces do not gape at the bend.
            parent.addChildNode(rod(from: from, to: to, radius: 0.075, extra: 0.03, hex: 0x8AA33A))
        }
        let end = path[path.count - 1]
        let heading = simd_normalize(end - path[path.count - 2])
        parent.addChildNode(rod(from: end - heading * 0.025, to: end + heading * 0.025, radius: 0.08, extra: 0, hex: 0x8A5A32))
    }

    /// A five-sided rod between two points.
    private static func rod(from: SIMD3<Float>, to: SIMD3<Float>, radius: CGFloat, extra: Float, hex: UInt32) -> SCNNode {
        let span = to - from
        let cylinder = SCNCylinder(radius: radius, height: CGFloat(simd_length(span) + extra))
        cylinder.radialSegmentCount = 5
        let paint = SCNMaterial()
        paint.lightingModel = .physicallyBased
        paint.diffuse.contents = LoaderStage.color(hex)
        paint.roughness.contents = 0.8
        paint.metalness.contents = 0.0
        cylinder.materials = [paint]
        let node = SCNNode(geometry: cylinder)
        node.simdPosition = (from + to) / 2
        node.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: simd_normalize(span))
        return node
    }

    /// Points along a Catmull-Rom curve through `points`, `steps` per span.
    private static func smooth(_ points: [SIMD3<Float>], steps: Int) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = [points[0]]
        for i in 0..<points.count - 1 {
            let p0 = points[max(i - 1, 0)], p1 = points[i]
            let p2 = points[i + 1], p3 = points[min(i + 2, points.count - 1)]
            for step in 1...steps {
                let t = Float(step) / Float(steps)
                var sum: SIMD3<Float> = p1 * 2
                sum += (p2 - p0) * t
                var square: SIMD3<Float> = p0 * 2
                square -= p1 * 5
                square += p2 * 4
                square -= p3
                sum += square * (t * t)
                var cube: SIMD3<Float> = p1 * 3
                cube -= p0
                cube -= p2 * 3
                cube += p3
                sum += cube * (t * t * t)
                out.append(sum * 0.5)
            }
        }
        return out
    }
}
