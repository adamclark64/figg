import AppKit
import FiggWidget
import SceneKit
import SwiftUI

/// A 3D loader as a SwiftUI view: the hopping fig newton or the spinning
/// fig, by `style`. It fills its frame and is clear around the drawing.
///
/// With `animated` it moves; without, it holds its still pose. The scene is
/// built once per view, so a view whose `style` may change needs a new
/// identity when it does (`FigLoader` uses `.id(style)`).
struct Loader3D: NSViewRepresentable {
    var style: LoaderStyle
    var progress: Double?
    var animated: Bool
    /// Top of the fig newton's hop as a share of a full one, for places
    /// with little room above it. The fig does not hop.
    var hopScale: Double = 1

    func makeCoordinator() -> LoaderDriver {
        LoaderDriver(model: style == .newton ? FigNewtonScene() : FigScene())
    }

    func makeNSView(context: Context) -> SCNView {
        let view = InertSceneView(frame: NSRect(x: 0, y: 0, width: 64, height: 48), options: nil)
        view.scene = context.coordinator.model.scene
        view.pointOfView = context.coordinator.model.cameraNode
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.progress = progress
        context.coordinator.hopScale = hopScale
        if animated {
            view.isPlaying = true
        } else {
            view.isPlaying = false
            context.coordinator.model.hold(progress: progress)
        }
    }

    static func dismantleNSView(_ view: SCNView, coordinator: LoaderDriver) {
        view.isPlaying = false
        view.delegate = nil
    }
}

/// Moves one loader's scene each frame. SceneKit calls it on its render
/// thread, which is where the scene may be changed while it is playing.
final class LoaderDriver: NSObject, SCNSceneRendererDelegate {
    let model: any LoaderModel
    private let lock = NSLock()
    private var latest: Double?
    private var scale: Double = 1
    private var started: TimeInterval?

    init(model: any LoaderModel) {
        self.model = model
    }

    /// Set from the main thread, read on the render thread.
    var progress: Double? {
        get { lock.lock(); defer { lock.unlock() }; return latest }
        set { lock.lock(); latest = newValue; lock.unlock() }
    }

    /// Set from the main thread, read on the render thread.
    var hopScale: Double {
        get { lock.lock(); defer { lock.unlock() }; return scale }
        set { lock.lock(); scale = min(max(newValue, 0), 1); lock.unlock() }
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        // Count from the first frame so every loader starts from its rest pose.
        let began = started ?? time
        started = began
        model.animate(at: time - began, progress: progress, hopScale: hopScale)
    }
}

/// A loader is decoration: it must not take clicks meant for the row,
/// button or window drag area it sits in.
private final class InertSceneView: SCNView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
