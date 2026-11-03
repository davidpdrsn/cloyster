/// Pure layout model. Coordinates are top-left origin, matching the Accessibility API.

public enum Axis: Sendable {
    /// Children sit side by side and share a height.
    case horizontal
    /// Children are stacked and share a width.
    case vertical
}

public enum Edge: Sendable {
    case leading
    case trailing
}

public enum Side: Sendable {
    case left
    case right
    case top
    case bottom

    var axis: Axis { self == .left || self == .right ? .horizontal : .vertical }
    var edge: Edge { self == .left || self == .top ? .leading : .trailing }
}

public struct Rect: Equatable, Sendable {
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

    public func contains(x: Double, y: Double) -> Bool {
        x >= self.x && x < self.x + width && y >= self.y && y < self.y + height
    }

    /// The edge closest to a point.
    public func nearestSide(x: Double, y: Double) -> Side {
        distances(x: x, y: y).min { $0.distance < $1.distance }?.side ?? .right
    }

    fileprivate func distances(x: Double, y: Double) -> [(side: Side, distance: Double)] {
        [
            (.left, abs(x - self.x)),
            (.right, abs(self.x + width - x)),
            (.top, abs(y - self.y)),
            (.bottom, abs(self.y + height - y)),
        ]
    }

    public func low(_ axis: Axis) -> Double { axis == .horizontal ? x : y }
    public func extent(_ axis: Axis) -> Double { axis == .horizontal ? width : height }
    func high(_ axis: Axis) -> Double { low(axis) + extent(axis) }
}

public struct Node<ID: Hashable>: Equatable {
    public enum Content: Equatable {
        case window(ID)
        case split(Axis, [Node])
    }

    public var content: Content
    var width: Double = 0
    var height: Double = 0

    public init(_ content: Content) {
        self.content = content
    }

    public static func window(_ id: ID) -> Node { Node(.window(id)) }
    public static func split(_ axis: Axis, _ children: [Node]) -> Node { Node(.split(axis, children)) }

    public var windowIDs: [ID] {
        switch content {
        case .window(let id): return [id]
        case .split(_, let children): return children.flatMap(\.windowIDs)
        }
    }

    func contains(_ id: ID) -> Bool { windowIDs.contains(id) }

    func extent(_ axis: Axis) -> Double { axis == .horizontal ? width : height }

    mutating func setExtent(_ axis: Axis, _ value: Double) {
        if axis == .horizontal { width = value } else { height = value }
    }

    /// Sizes this node and its descendants, dividing space evenly between children.
    mutating func fit(width: Double, height: Double, gap: Double) {
        self.width = width
        self.height = height
        guard case .split(let axis, var children) = content else { return }
        let total = axis == .horizontal ? width : height
        let share = (total - gap * Double(children.count - 1)) / Double(children.count)
        for i in children.indices {
            children[i].fit(
                width: axis == .horizontal ? share : width,
                height: axis == .vertical ? share : height,
                gap: gap
            )
        }
        content = .split(axis, children)
    }

    /// Changes this node's size along `axis`.
    ///
    /// A split running along the axis gives the whole change to one child, so its siblings keep
    /// their size. A split running across the axis passes it to every child, because they have to
    /// stay the same size. `target` picks the child on the path to a window, otherwise the child
    /// at `edge` absorbs the change.
    mutating func grow(_ axis: Axis, by delta: Double, at edge: Edge, toward target: ID? = nil) {
        setExtent(axis, extent(axis) + delta)
        guard case .split(let splitAxis, var children) = content else { return }
        if splitAxis == axis {
            let i = childIndex(children, axis: edge, toward: target)
            children[i].grow(axis, by: delta, at: edge, toward: target)
        } else {
            for i in children.indices {
                let onPath = target.map(children[i].contains) ?? false
                children[i].grow(axis, by: delta, at: edge, toward: onPath ? target : nil)
            }
        }
        content = .split(splitAxis, children)
    }

    /// How far `grow` can shrink this node before a window drops below `minSize`.
    func slack(_ axis: Axis, at edge: Edge, toward target: ID? = nil, minSize: Double) -> Double {
        guard case .split(let splitAxis, let children) = content else {
            return extent(axis) - minSize
        }
        if splitAxis == axis {
            let i = childIndex(children, axis: edge, toward: target)
            return children[i].slack(axis, at: edge, toward: target, minSize: minSize)
        }
        return children.map { child in
            let onPath = target.map(child.contains) ?? false
            return child.slack(axis, at: edge, toward: onPath ? target : nil, minSize: minSize)
        }.min() ?? 0
    }

    private func childIndex(_ children: [Node], axis edge: Edge, toward target: ID?) -> Int {
        if let target, let i = children.firstIndex(where: { $0.contains(target) }) {
            return i
        }
        return edge == .leading ? 0 : children.count - 1
    }
}

public struct Divider: Equatable, Sendable {
    /// Child indices leading from the root to the split that owns this divider.
    public var path: [Int]
    /// The divider sits between children `index` and `index + 1`.
    public var index: Int
    public var axis: Axis
    public var frame: Rect
}

public struct Cluster<ID: Hashable>: Equatable {
    public private(set) var root: Node<ID>
    public private(set) var x: Double
    public private(set) var y: Double
    public let gap: Double
    public let minSize: Double

    public init(root: Node<ID>, frame: Rect, gap: Double = 12, minSize: Double = 120) {
        self.root = root
        self.x = frame.x
        self.y = frame.y
        self.gap = gap
        self.minSize = minSize
        self.root.fit(width: frame.width, height: frame.height, gap: gap)
    }

    public var frames: [ID: Rect] {
        var result: [ID: Rect] = [:]
        walk(root, x: x, y: y, path: []) { node, rect, _ in
            if case .window(let id) = node.content { result[id] = rect }
        }
        return result
    }

    public var dividers: [Divider] {
        var result: [Divider] = []
        walk(root, x: x, y: y, path: []) { node, rect, path in
            guard case .split(let axis, let children) = node.content else { return }
            var offset = 0.0
            for (i, child) in children.dropLast().enumerated() {
                offset += child.extent(axis)
                let frame = axis == .horizontal
                    ? Rect(x: rect.x + offset, y: rect.y, width: gap, height: rect.height)
                    : Rect(x: rect.x, y: rect.y + offset, width: rect.width, height: gap)
                result.append(Divider(path: path, index: i, axis: axis, frame: frame))
                offset += gap
            }
        }
        return result
    }

    private func walk(
        _ node: Node<ID>, x: Double, y: Double, path: [Int],
        _ visit: (Node<ID>, Rect, [Int]) -> Void
    ) {
        visit(node, Rect(x: x, y: y, width: node.width, height: node.height), path)
        guard case .split(let axis, let children) = node.content else { return }
        var x = x
        var y = y
        for (i, child) in children.enumerated() {
            walk(child, x: x, y: y, path: path + [i], visit)
            if axis == .horizontal { x += child.width + gap } else { y += child.height + gap }
        }
    }

    /// Moves a divider, keeping the combined size of its neighbours. Returns the distance moved.
    @discardableResult
    public mutating func moveDivider(_ divider: Divider, by delta: Double) -> Double {
        var applied = 0.0
        let minSize = minSize
        Self.withNode(&root, at: divider.path[...]) { node in
            guard case .split(let axis, var children) = node.content else { return }
            let i = divider.index
            let lower = -children[i].slack(axis, at: .trailing, minSize: minSize)
            let upper = children[i + 1].slack(axis, at: .leading, minSize: minSize)
            applied = min(max(delta, lower), upper)
            children[i].grow(axis, by: applied, at: .trailing)
            children[i + 1].grow(axis, by: -applied, at: .leading)
            node.content = .split(axis, children)
        }
        return applied
    }

    private static func withNode(
        _ node: inout Node<ID>, at path: ArraySlice<Int>, _ body: (inout Node<ID>) -> Void
    ) {
        guard let next = path.first else { return body(&node) }
        guard case .split(let axis, var children) = node.content else { return }
        withNode(&children[next], at: path.dropFirst(), body)
        node.content = .split(axis, children)
    }

    /// Adopts a frame the user gave a window, by moving the cluster and resizing as needed.
    ///
    /// Growing a window only affects windows that have to match it: its column for width, its row
    /// for height. Everything else keeps its size, so the cluster's outer size changes instead.
    public mutating func update(_ id: ID, to frame: Rect) {
        guard let old = frames[id] else { return }
        let horizontal = adopt(id, .horizontal, old: old, new: frame)
        let vertical = adopt(id, .vertical, old: old, new: frame)
        guard let current = frames[id] else { return }
        x += horizontal - (horizontal == frame.x ? current.x : current.x + current.width)
        y += vertical - (vertical == frame.y ? current.y : current.y + current.height)
    }

    /// Applies the size change along one axis and returns the coordinate of the edge that stayed
    /// put, which the cluster is then re-anchored to.
    private mutating func adopt(_ id: ID, _ axis: Axis, old: Rect, new: Rect) -> Double {
        let edge: Edge = abs(new.low(axis) - old.low(axis)) > 0.5 ? .leading : .trailing
        let delta = new.extent(axis) - old.extent(axis)
        guard delta != 0 else { return new.low(axis) }
        let lower = -root.slack(axis, at: edge, toward: id, minSize: minSize)
        root.grow(axis, by: max(delta, lower), at: edge, toward: id)
        return edge == .leading ? new.high(axis) : new.low(axis)
    }

    /// Removes a window, giving its space to the neighbouring window. Returns false if nothing
    /// would remain.
    public mutating func remove(_ id: ID) -> Bool {
        guard root.windowIDs != [id] else { return false }
        let before = frames[id]
        Self.remove(id, from: &root, gap: gap)
        if let before, !root.contains(id), frames.isEmpty == false {
            x = min(x, before.x)
            y = min(y, before.y)
        }
        return true
    }

    private static func remove(_ id: ID, from node: inout Node<ID>, gap: Double) {
        guard case .split(let axis, var children) = node.content else { return }
        guard let i = children.firstIndex(where: { $0.contains(id) }) else { return }
        if children[i].windowIDs != [id] {
            remove(id, from: &children[i], gap: gap)
            node.content = .split(axis, children)
            return
        }
        let freed = children[i].extent(axis) + gap
        children.remove(at: i)
        if i < children.count {
            children[i].grow(axis, by: freed, at: .leading)
        } else {
            children[i - 1].grow(axis, by: freed, at: .trailing)
        }
        if children.count == 1 {
            node = children[0]
        } else {
            node.content = .split(axis, children)
        }
    }
}

/// Where a dragged window would join a cluster.
public struct Drop<ID: Hashable>: Equatable {
    /// The window to join next to, or nil to run along a whole side of the cluster.
    public var target: ID?
    public var side: Side

    public init(target: ID?, side: Side) {
        self.target = target
        self.side = side
    }
}

extension Cluster {
    /// How close to a cluster's outer edge the cursor must be to join the whole side.
    static var outerMargin: Double { 40 }

    /// How close to a window's edge the cursor must be to join it. The middle of a window never
    /// joins, because maximized windows sit behind almost everything and would otherwise catch
    /// every drop.
    static var joinMargin: Double { 80 }

    public var bounds: Rect { Rect(x: x, y: y, width: root.width, height: root.height) }

    /// Picks where a window dropped at a point joins, given the window under the cursor. Returns
    /// nil if the point is too far from that window's edges.
    public func drop(x: Double, y: Double, over id: ID) -> Drop<ID>? {
        guard
            let frame = frames[id],
            let nearest = frame.distances(x: x, y: y).map(\.distance).min(),
            nearest <= Self.joinMargin
        else { return nil }
        if root.windowIDs.count > 1,
            let outer = bounds.distances(x: x, y: y).min(by: { $0.distance < $1.distance }),
            outer.distance <= Self.outerMargin
        {
            return Drop(target: nil, side: outer.side)
        }
        return Drop(target: id, side: frame.nearestSide(x: x, y: y))
    }

    /// Adds a window, which keeps its size along the side it joins and matches the rest of the
    /// cluster across it. The window it joins stays put, so the cluster grows.
    public mutating func attach(_ id: ID, size: Rect, at drop: Drop<ID>) {
        let axis = drop.side.axis
        let length = max(size.extent(axis), minSize)
        let anchor = drop.target.flatMap { frames[$0] }
        let leading = drop.side.edge == .leading
        if let target = drop.target {
            root.grow(axis, by: length + gap, at: drop.side.edge, toward: target)
            Self.insert(id, length: length, next: target, side: drop.side, gap: gap, in: &root)
        } else {
            Self.wrap(id, length: length, side: drop.side, gap: gap, root: &root)
            if leading {
                if axis == .horizontal { x -= length + gap } else { y -= length + gap }
            }
        }
        if let anchor, let target = drop.target, let current = frames[target] {
            x += anchor.x - current.x
            y += anchor.y - current.y
        }
    }

    /// The frame a window would get from a drop, without changing the cluster.
    public func preview(_ id: ID, size: Rect, at drop: Drop<ID>) -> Rect? {
        var copy = self
        if frames[id] != nil, !copy.remove(id) { return nil }
        copy.attach(id, size: size, at: drop)
        return copy.frames[id]
    }

    /// Splits the target window's space, which has already grown to fit the new window.
    private static func insert(
        _ id: ID, length: Double, next target: ID, side: Side, gap: Double, in node: inout Node<ID>
    ) {
        switch node.content {
        case .window:
            var existing = node
            existing.setExtent(side.axis, node.extent(side.axis) - length - gap)
            var added = Node<ID>.window(id)
            added.width = node.width
            added.height = node.height
            added.setExtent(side.axis, length)
            node.content = .split(side.axis, side.edge == .leading ? [added, existing] : [existing, added])
        case .split(let axis, var children):
            guard let i = children.firstIndex(where: { $0.contains(target) }) else { return }
            var child = children[i]
            let wasWindow = child.windowIDs == [target]
            insert(id, length: length, next: target, side: side, gap: gap, in: &child)
            if wasWindow, axis == side.axis, case .split(_, let pair) = child.content {
                children.replaceSubrange(i...i, with: pair)
            } else {
                children[i] = child
            }
            node.content = .split(axis, children)
        }
    }

    /// Adds a window along a whole side of the cluster.
    private static func wrap(_ id: ID, length: Double, side: Side, gap: Double, root: inout Node<ID>) {
        var added = Node<ID>.window(id)
        added.width = root.width
        added.height = root.height
        added.setExtent(side.axis, length)
        let extent = root.extent(side.axis) + length + gap
        if case .split(let axis, var children) = root.content, axis == side.axis {
            children.insert(added, at: side.edge == .leading ? 0 : children.count)
            root.content = .split(axis, children)
        } else {
            let existing = root
            root.content = .split(side.axis, side.edge == .leading ? [added, existing] : [existing, added])
        }
        root.setExtent(side.axis, extent)
    }
}

extension Node {
    /// Rebuilds the tree with new window IDs. Returns nil if any window can't be mapped.
    public func mapWindows<T>(_ transform: (ID) -> T?) -> Node<T>? {
        switch content {
        case .window(let id):
            return transform(id).map(Node<T>.window)
        case .split(let axis, let children):
            var mapped: [Node<T>] = []
            for child in children {
                guard let node = child.mapWindows(transform) else { return nil }
                mapped.append(node)
            }
            return .split(axis, mapped)
        }
    }
}

extension Node where ID == String {
    /// Parses a layout such as `h(Safari,v(Terminal,Notes))`.
    public static func parse(_ text: String) -> Node? {
        var rest = text[...]
        guard let node = parseNode(&rest), rest.isEmpty else { return nil }
        return node
    }

    private static func parseNode(_ rest: inout Substring) -> Node? {
        for (prefix, axis) in [("h(", Axis.horizontal), ("v(", Axis.vertical)] where rest.hasPrefix(prefix) {
            rest = rest.dropFirst(2)
            var children: [Node] = []
            while true {
                guard let child = parseNode(&rest) else { return nil }
                children.append(child)
                guard let next = rest.popFirst() else { return nil }
                if next == ")" { break }
                if next != "," { return nil }
            }
            return children.count > 1 ? .split(axis, children) : nil
        }
        let name = rest.prefix { $0 != "," && $0 != ")" && $0 != "(" }
        rest = rest.dropFirst(name.count)
        return name.isEmpty ? nil : .window(String(name))
    }
}
