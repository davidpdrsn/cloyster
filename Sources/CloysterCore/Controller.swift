extension Rect {
    public func differs(from other: Rect) -> Bool {
        abs(x - other.x) > 0.5 || abs(y - other.y) > 0.5
            || abs(width - other.width) > 0.5 || abs(height - other.height) > 0.5
    }
}

/// Keeps one cluster's real windows in step with its layout.
///
/// While the mouse is down the first window to change becomes the leader and everything else
/// follows it. The leader is never written to mid-gesture because the user is driving it.
public final class Controller {
    public private(set) var cluster: Cluster<WindowID>
    public private(set) var windows: Set<WindowID>
    private let system: WindowSystem
    private let stats: Stats
    private var surface: ClusterSurface?

    /// Last frame we asked for, or saw the user set, per window.
    private var written: [WindowID: Rect] = [:]
    /// What windows settled on after our writes, which can differ if they refuse a size.
    private var settled: [WindowID: Rect] = [:]
    private var leader: WindowID?
    private var draggingDivider = false
    private var lastDivider: Divider?
    /// Windows whose refused size has been adopted since the last gesture. Each gets one turn, so
    /// two windows that snap to different sizes can't chase each other forever.
    private var reconciled: Set<WindowID> = []

    /// Stops following windows, for when one is being dragged out of the cluster.
    var isPaused = false

    init(cluster: Cluster<WindowID>, system: WindowSystem, stats: Stats) {
        self.cluster = cluster
        self.windows = Set(cluster.root.windowIDs)
        self.system = system
        self.stats = stats
    }

    public var name: String {
        cluster.root.windowIDs.compactMap(system.appName).joined(separator: " + ")
    }

    func start() {
        surface = system.makeSurface(DividerHandlers(
            onBegin: { [weak self] in
                self?.beginGesture()
                self?.draggingDivider = true
            },
            onDrag: { [weak self] divider, delta in self?.moveDivider(divider, by: delta) ?? 0 },
            onEnd: { [weak self] in
                self?.draggingDivider = false
                self?.restack()
            }
        ))
        push()
        syncSurface()
        restack()
    }

    func close() {
        surface?.close()
        surface = nil
    }

    func beginGesture() {
        leader = nil
        lastDivider = nil
        reconciled = []
    }

    func endGesture() {
        if leader != nil {
            leader = nil
            push()
            syncSurface()
        }
        restack()
    }

    func poll(gesture: Bool) {
        guard !draggingDivider, !isPaused else { return }
        let current = system.frames(of: Array(windows))
        removeClosedWindows(current)
        guard !windows.isEmpty else { return }

        if !gesture {
            guard windows.allSatisfy(system.isIdle) else { return }
            reconcile()
        }

        let frames = cluster.frames
        if let leader {
            sampleDrift(current, frames, leader: leader)
        }
        let changed = leader ?? windows.first { id in
            guard let frame = current[id], let expected = frames[id] else { return false }
            return frame.differs(from: expected) && settled[id].map { frame.differs(from: $0) } ?? true
        }
        guard let changed, let frame = current[changed], let expected = frames[changed] else { return }
        guard frame.differs(from: expected) else { return }

        if gesture { leader = changed }
        cluster.update(changed, to: frame)
        written[changed] = frame
        settled[changed] = nil
        push(except: gesture ? changed : nil)
        syncSurface()
    }

    /// Windows can refuse a size, by having a minimum or snapping to character cells. Adopts what
    /// they settled on so the cluster stays aligned. After a divider drag the divider gives way,
    /// keeping the combined size. Otherwise the window's row or column follows it.
    private func reconcile() {
        // Decided up front, because adopting one window changes what the others are expected to be.
        let refused = settled.filter { id, actual in
            !reconciled.contains(id) && written[id].map { actual.differs(from: $0) } ?? false
        }
        for (id, actual) in refused {
            guard let expected = cluster.frames[id] else { continue }
            reconciled.insert(id)
            var target = actual
            if let divider = lastDivider {
                let axis = divider.axis
                let excess = actual.extent(axis) - expected.extent(axis)
                let trailing = expected.low(axis) > divider.frame.low(axis)
                cluster.moveDivider(divider, by: trailing ? -excess : excess)
                guard let moved = cluster.frames[id] else { continue }
                if axis == .horizontal {
                    target = Rect(x: moved.x, y: actual.y, width: moved.width, height: actual.height)
                } else {
                    target = Rect(x: actual.x, y: moved.y, width: actual.width, height: moved.height)
                }
            }
            cluster.update(id, to: target)
        }
        if !refused.isEmpty {
            push()
            syncSurface()
        }
    }

    private func sampleDrift(_ current: [WindowID: Rect], _ frames: [WindowID: Rect], leader: WindowID) {
        for (id, expected) in frames where id != leader {
            guard let frame = current[id] else { continue }
            stats.drift.append(max(abs(frame.x - expected.x), abs(frame.y - expected.y)))
        }
    }

    private func removeClosedWindows(_ current: [WindowID: Rect]) {
        let closed = windows.filter { current[$0] == nil }
        guard !closed.isEmpty else { return }
        closed.forEach(forget)
        fillGaps()
    }

    private func forget(_ id: WindowID) {
        windows.remove(id)
        written[id] = nil
        settled[id] = nil
        if leader == id { leader = nil }
        if !cluster.remove(id) { windows.removeAll() }
    }

    /// Takes a window out, leaving it wherever it is. Its neighbours fill the space.
    func detach(_ id: WindowID) {
        forget(id)
        fillGaps()
    }

    /// A lone window isn't a cluster any more, so it keeps its size rather than filling the space.
    private func fillGaps() {
        if windows.count > 1 { push() }
        syncSurface()
    }

    func attach(_ id: WindowID, size: Rect, at drop: Drop<WindowID>) {
        windows.insert(id)
        written[id] = nil
        settled[id] = nil
        reconciled = []
        cluster.attach(id, size: size, at: drop)
        push()
        syncSurface()
        restack()
    }

    /// Puts a window back where the layout says it belongs.
    func restore(_ id: WindowID) {
        written[id] = nil
        push()
    }

    /// Records what a window actually ended up as after our last write.
    func settle(_ id: WindowID, at frame: Rect) {
        settled[id] = frame
    }

    private func push(except excluded: WindowID? = nil) {
        for (id, frame) in cluster.frames where id != excluded {
            guard windows.contains(id) else { continue }
            let previous = written[id]
            guard previous != frame else { continue }
            written[id] = frame
            system.write(
                id,
                frame: frame,
                setPosition: previous.map { $0.x != frame.x || $0.y != frame.y } ?? true,
                setSize: previous.map { $0.width != frame.width || $0.height != frame.height } ?? true
            )
        }
    }

    private func syncSurface() {
        surface?.show(cluster.dividers)
    }

    private func moveDivider(_ divider: Divider, by delta: Double) -> Double {
        let moved = cluster.moveDivider(divider, by: delta)
        lastDivider = divider
        push()
        syncSurface()
        return moved
    }

    /// Raises the cluster's windows to the top of `order`, which runs front to back and starts
    /// with one of them. That window stays in front.
    func raise(order: [WindowID]) {
        let visible = order.filter(windows.contains)
        guard let front = visible.first, Set(order.prefix(visible.count)) != Set(visible) else { return }
        system.raise(visible.dropFirst() + [front]) { [weak self] in self?.restack() }
    }

    /// Keeps dividers just above the cluster rather than floating over unrelated windows.
    func restack() {
        guard let front = system.normalWindows().first(where: { windows.contains($0.id) }) else { return }
        surface?.restack(above: front.id)
    }
}
