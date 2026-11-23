import CoreGraphics
import Foundation

/// A copy of one Accessibility element and its children, taken from a
/// meeting app's window by `AXTreeCapture`. A plain value, so profiles can
/// turn it into a snapshot without touching the Accessibility API, and so
/// captured trees can be saved as JSON and used as test fixtures.
///
/// Only text the profiles need is kept. `value` is cut to `maxText`
/// characters: a profile needs labels, never a long text field's contents.
public struct AXNode: Codable, Sendable, Equatable {
    public struct Frame: Codable, Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public var role: String?
    public var subrole: String?
    public var roleDescription: String?
    public var title: String?
    public var description: String?
    public var value: String?
    /// AXIdentifier (native apps, e.g. Zoom's "zm.meeting.window.main").
    public var identifier: String?
    /// AXDOMIdentifier (web content: the element's DOM id).
    public var domID: String?
    /// AXDOMClassList (web content: the element's DOM classes).
    public var domClasses: [String]?
    /// AXURL, on web areas.
    public var url: String?
    /// Relative to the top-left of the captured target; nil when the
    /// capture did not ask for it.
    public var frame: Frame?
    public var children: [AXNode]

    public static let maxText = 200

    public init(role: String? = nil, subrole: String? = nil, roleDescription: String? = nil, title: String? = nil,
                description: String? = nil, value: String? = nil, identifier: String? = nil, domID: String? = nil,
                domClasses: [String]? = nil, url: String? = nil, frame: Frame? = nil, children: [AXNode] = []) {
        self.role = role
        self.subrole = subrole
        self.roleDescription = roleDescription
        self.title = title
        self.description = description
        self.value = value.map(Self.cut)
        self.identifier = identifier
        self.domID = domID
        self.domClasses = domClasses
        self.url = url
        self.frame = frame
        self.children = children
    }

    enum CodingKeys: String, CodingKey {
        case role, subrole, roleDescription, title, description, value, identifier, domID, domClasses, url, frame, children
    }

    /// Written by hand so fixtures can leave out any key, `children` included.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        subrole = try c.decodeIfPresent(String.self, forKey: .subrole)
        roleDescription = try c.decodeIfPresent(String.self, forKey: .roleDescription)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        value = try c.decodeIfPresent(String.self, forKey: .value).map(Self.cut)
        identifier = try c.decodeIfPresent(String.self, forKey: .identifier)
        domID = try c.decodeIfPresent(String.self, forKey: .domID)
        domClasses = try c.decodeIfPresent([String].self, forKey: .domClasses)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        frame = try c.decodeIfPresent(Frame.self, forKey: .frame)
        children = try c.decodeIfPresent([AXNode].self, forKey: .children) ?? []
    }

    /// Encoded by hand so an empty `children` is left out, keeping fixtures short.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(role, forKey: .role)
        try c.encodeIfPresent(subrole, forKey: .subrole)
        try c.encodeIfPresent(roleDescription, forKey: .roleDescription)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(identifier, forKey: .identifier)
        try c.encodeIfPresent(domID, forKey: .domID)
        try c.encodeIfPresent(domClasses, forKey: .domClasses)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(frame, forKey: .frame)
        if !children.isEmpty { try c.encode(children, forKey: .children) }
    }

    static func cut(_ s: String) -> String {
        s.count > maxText ? String(s.prefix(maxText)) : s
    }

    /// The description, else the title: what most apps put their label in.
    public var label: String? { description ?? title }

    /// Every node in the tree, this one first, depth first.
    public func all(where match: (AXNode) -> Bool = { _ in true }) -> [AXNode] {
        var out: [AXNode] = []
        func visit(_ n: AXNode) {
            if match(n) { out.append(n) }
            for c in n.children { visit(c) }
        }
        visit(self)
        return out
    }

    /// The first node, depth first, that matches.
    public func first(where match: (AXNode) -> Bool) -> AXNode? {
        if match(self) { return self }
        for c in children { if let hit = c.first(where: match) { return hit } }
        return nil
    }

    /// Visits every node with its ancestors (nearest last), so a profile can
    /// ask "is this inside the Participants panel" without parent pointers.
    /// Returning false from `body` skips that node's children.
    public func walk(_ body: (AXNode, [AXNode]) -> Bool) {
        var path: [AXNode] = []
        func visit(_ n: AXNode) {
            guard body(n, path) else { return }
            path.append(n)
            for c in n.children { visit(c) }
            path.removeLast()
        }
        visit(self)
    }
}

/// What one capture of a meeting app returned: the target (a window, or one
/// web area in a browser) and, when the profile asks for it, a shallow copy
/// of the app's other windows (Zoom's self name is in its main window).
/// Codable, so a capture is a fixture as it stands.
public struct MeetingAppCapture: Codable, Sendable, Equatable {
    public var tree: AXNode
    public var width: Double
    public var height: Double
    public var otherWindows: [AXNode]

    public init(tree: AXNode, width: Double, height: Double, otherWindows: [AXNode] = []) {
        self.tree = tree
        self.width = width
        self.height = height
        self.otherWindows = otherWindows
    }

    enum CodingKeys: String, CodingKey { case tree, width, height, otherWindows }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tree = try c.decode(AXNode.self, forKey: .tree)
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? tree.frame?.width ?? 0
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? tree.frame?.height ?? 0
        otherWindows = try c.decodeIfPresent([AXNode].self, forKey: .otherWindows) ?? []
    }

    public static func decode(_ data: Data) throws -> MeetingAppCapture {
        try JSONDecoder().decode(MeetingAppCapture.self, from: data)
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }
}

/// The cheap first look at one of an app's windows, enough for a profile to
/// pick its target without copying anything else.
public struct AXWindowSummary: Sendable, Equatable {
    public struct WebArea: Sendable, Equatable {
        public var url: String?
        public var title: String?
        public init(url: String?, title: String? = nil) {
            self.url = url
            self.title = title
        }
    }

    public var index: Int
    public var title: String?
    public var identifier: String?
    /// Only filled for profiles that read web content.
    public var webAreas: [WebArea]

    public init(index: Int, title: String? = nil, identifier: String? = nil, webAreas: [WebArea] = []) {
        self.index = index
        self.title = title
        self.identifier = identifier
        self.webAreas = webAreas
    }
}

/// Which part of an app a profile wants copied.
public enum AXTarget: Sendable, Equatable {
    /// The whole window at this index in the app's window list.
    case window(Int)
    /// The web area with this URL in the window at this index; nothing else
    /// in the browser is copied.
    case webArea(window: Int, url: String)
}

/// How far a capture may go. `descend` and `wantsFrame` see a node before
/// its children are read, so a profile can skip subtrees it never needs and
/// ask for positions (two extra calls per node) only where it uses them.
public struct CapturePolicy: Sendable {
    public var maxNodes: Int
    /// Nodes deeper than this (the target is depth 0) are not read.
    public var maxDepth: Int
    /// Depth of the copy of the app's other windows; nil reads none.
    public var otherWindowsDepth: Int?
    /// Whether summaries need the web areas (and their URLs) of each window.
    public var findsWebAreas: Bool
    public var descend: @Sendable (AXNode) -> Bool
    public var wantsFrame: @Sendable (AXNode) -> Bool

    public init(maxNodes: Int = 4000, maxDepth: Int = 8, otherWindowsDepth: Int? = nil, findsWebAreas: Bool = false,
                descend: @escaping @Sendable (AXNode) -> Bool = { _ in true },
                wantsFrame: @escaping @Sendable (AXNode) -> Bool = { _ in false }) {
        self.maxNodes = maxNodes
        self.maxDepth = maxDepth
        self.otherWindowsDepth = otherWindowsDepth
        self.findsWebAreas = findsWebAreas
        self.descend = descend
        self.wantsFrame = wantsFrame
    }
}
