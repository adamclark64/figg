import AppKit
import ApplicationServices
import Foundation

/// The only code in figg that walks other apps' Accessibility trees. It
/// copies what a `MeetingAppProfile` asks for into `AXNode` values and
/// nothing else. Every call has the 250 ms timeout set on the app element
/// by the reader, and every walk has a node and depth cap, so a hung or
/// huge app costs a gap in the timeline, never the recording.
enum AXTreeCapture {
    /// Read in one call per element.
    static let attributes: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXRoleDescriptionAttribute, kAXTitleAttribute,
        kAXDescriptionAttribute, kAXValueAttribute, "AXIdentifier", "AXDOMIdentifier", "AXDOMClassList", "AXURL",
    ]

    /// One element's own attributes, without children or frame.
    static func node(_ e: AXUIElement) -> AXNode {
        var raw: CFArray?
        let names = attributes as CFArray
        guard AXUIElementCopyMultipleAttributeValues(e, names, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
              let values = raw as? [Any], values.count == attributes.count else { return AXNode() }
        func text(_ i: Int) -> String? {
            guard let s = values[i] as? String, !s.isEmpty else { return nil }
            return s
        }
        let classes = (values[8] as? [Any])?.compactMap { $0 as? String }
        let url = (values[9] as? URL)?.absoluteString ?? (values[9] as? String)
        return AXNode(role: text(0), subrole: text(1), roleDescription: text(2), title: text(3), description: text(4),
                      value: text(5), identifier: text(6), domID: text(7),
                      domClasses: classes?.isEmpty == false ? classes : nil, url: url)
    }

    /// Copies `root` and its children as `policy` allows, frames relative to `origin`.
    static func copy(_ root: AXUIElement, policy: CapturePolicy, origin: CGPoint) -> AXNode {
        var visited = 0
        func visit(_ e: AXUIElement, depth: Int) -> AXNode {
            visited += 1
            var n = node(e)
            if depth == 0 || policy.wantsFrame(n) { n.frame = frame(e, origin: origin) }
            guard depth < policy.maxDepth, visited < policy.maxNodes, policy.descend(n),
                  let kids: [AXUIElement] = AX.value(e, kAXChildrenAttribute) else { return n }
            for k in kids {
                guard visited < policy.maxNodes else { break }
                n.children.append(visit(k, depth: depth + 1))
            }
            return n
        }
        return visit(root, depth: 0)
    }

    static func frame(_ e: AXUIElement, origin: CGPoint) -> AXNode.Frame {
        let p = AX.position(e), s = AX.size(e)
        return .init(x: p.x - origin.x, y: p.y - origin.y, width: s.width, height: s.height)
    }

    /// A window's web areas, found without going inside any of them. Small
    /// caps: browser chrome is shallow, and this runs on every poll.
    static func webAreas(in window: AXUIElement) -> [(element: AXUIElement, area: AXWindowSummary.WebArea)] {
        var out: [(AXUIElement, AXWindowSummary.WebArea)] = []
        var visited = 0
        func visit(_ e: AXUIElement, depth: Int) {
            visited += 1
            guard visited < 600 else { return }
            if AX.string(e, kAXRoleAttribute) == "AXWebArea" {
                let url: URL? = AX.value(e, "AXURL")
                out.append((e, .init(url: url?.absoluteString, title: AX.string(e, kAXTitleAttribute))))
                return
            }
            guard depth < 20, let kids: [AXUIElement] = AX.value(e, kAXChildrenAttribute) else { return }
            for k in kids { visit(k, depth: depth + 1) }
        }
        visit(window, depth: 0)
        return out
    }

    /// The app's windows, summarised, with the elements to resolve a target.
    struct Windows {
        var elements: [AXUIElement]
        var summaries: [AXWindowSummary]
        var webAreaElements: [Int: [(element: AXUIElement, area: AXWindowSummary.WebArea)]]

        func element(for target: AXTarget) -> AXUIElement? {
            switch target {
            case .window(let i):
                return elements.indices.contains(i) ? elements[i] : nil
            case .webArea(let i, let url):
                return webAreaElements[i]?.first { $0.area.url == url }?.element
            }
        }
    }

    static func windows(of app: AXUIElement, findsWebAreas: Bool) -> Windows {
        let elements: [AXUIElement] = AX.value(app, kAXWindowsAttribute) ?? []
        var summaries: [AXWindowSummary] = []
        var areas: [Int: [(element: AXUIElement, area: AXWindowSummary.WebArea)]] = [:]
        for (i, w) in elements.enumerated() {
            var s = AXWindowSummary(index: i, title: AX.string(w, kAXTitleAttribute), identifier: AX.string(w, "AXIdentifier"))
            if findsWebAreas {
                let found = webAreas(in: w)
                areas[i] = found
                s.webAreas = found.map(\.area)
            }
            summaries.append(s)
        }
        return Windows(elements: elements, summaries: summaries, webAreaElements: areas)
    }
}

/// Whether figg may read other apps' windows, and asking for it.
public enum AccessibilityAccess {
    public static var isGranted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own prompt (once per app) that opens Privacy & Security >
    /// Accessibility, and adds figg to that list.
    public static func request() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Small typed wrappers over the AX C API.
enum AX {
    static func value<T>(_ e: AXUIElement, _ attribute: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success else { return nil }
        return v as? T
    }

    static func string(_ e: AXUIElement, _ attribute: String) -> String? {
        let s: String? = value(e, attribute)
        return s?.isEmpty == false ? s : nil
    }

    /// Top-left corner in screen points (y grows downwards), or zero.
    static func position(_ e: AXUIElement) -> CGPoint {
        var v: CFTypeRef?
        var point = CGPoint.zero
        if AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &v) == .success, let v,
           CFGetTypeID(v) == AXValueGetTypeID() {
            AXValueGetValue(v as! AXValue, .cgPoint, &point)
        }
        return point
    }

    static func size(_ e: AXUIElement) -> CGSize {
        var v: CFTypeRef?
        var size = CGSize.zero
        if AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &v) == .success, let v,
           CFGetTypeID(v) == AXValueGetTypeID() {
            AXValueGetValue(v as! AXValue, .cgSize, &size)
        }
        return size
    }
}
