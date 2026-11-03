import AppKit
import CloysterCore

extension Rect {
    func differs(from other: Rect) -> Bool {
        abs(x - other.x) > 0.5 || abs(y - other.y) > 0.5
            || abs(width - other.width) > 0.5 || abs(height - other.height) > 0.5
    }
}

/// Keeps one cluster's real windows in step with its layout.
///
/// While the mouse is down the first window to change becomes the leader and everything else
/// follows it. The leader is never written to mid-gesture because the user is driving it.
final class Controller {
    private(set) var cluster: Cluster<CGWindowID>
    private(set) var windows: [CGWindowID: AXWindow]
    private let writer: (AXWindow) -> Writer
    private let stats: Stats
    private var panels: [DividerPanel] = []
    private let raiseQueue = DispatchQueue(label: "cloyster.raise", qos: .userInteractive)

    /// Last frame we asked for, or saw the user set, per window.
    private var written: [CGWindowID: Rect] = [:]
    /// What windows settled on after our writes, which can differ if they refuse a size.
    private var settled: [CGWindowID: Rect] = [:]
    private var leader: CGWindowID?
    private var draggingDivider = false
    private var lastDivider: Divider?
    /// Windows whose refused size has been adopted since the last gesture. Each gets one turn, so
    /// two windows that snap to different sizes can't chase each other forever.
    private var reconciled: Set<CGWindowID> = []

    /// Stops following windows, for when one is being dragged out of the cluster.
    var isPaused = false

    init(cluster: Cluster<CGWindowID>, windows: [AXWindow], stats: Stats, writer: @escaping (AXWindow) -> Writer) {
        self.cluster = cluster
        self.windows = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        self.stats = stats
        self.writer = writer
    }

    var name: String {
        cluster.root.windowIDs.compactMap { windows[$0]?.appName }.joined(separator: " + ")
    }

    func start() {
        push()
        syncPanels()
        restack()
    }

    func close() {
        panels.forEach { $0.close() }
        panels = []
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
            syncPanels()
        }
        restack()
    }

    func poll(gesture: Bool) {
        guard !draggingDivider, !isPaused else { return }
        let current = windowServerFrames(Array(windows.keys))
        removeClosedWindows(current)
        guard !windows.isEmpty else { return }

        if !gesture {
            guard windows.values.allSatisfy({ writer($0).isIdle }) else { return }
            reconcile()
        }

        let frames = cluster.frames
        if let leader {
            sampleDrift(current, frames, leader: leader)
        }
        let changed = leader ?? windows.keys.first { id in
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
        syncPanels()
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
            syncPanels()
        }
    }

    private func sampleDrift(_ current: [CGWindowID: Rect], _ frames: [CGWindowID: Rect], leader: CGWindowID) {
        for (id, expected) in frames where id != leader {
            guard let frame = current[id] else { continue }
            stats.drift.append(max(abs(frame.x - expected.x), abs(frame.y - expected.y)))
        }
    }

    private func removeClosedWindows(_ current: [CGWindowID: Rect]) {
        let closed = windows.keys.filter { current[$0] == nil }
        guard !closed.isEmpty else { return }
        closed.forEach(forget)
        fillGaps()
    }

    private func forget(_ id: CGWindowID) {
        windows[id] = nil
        written[id] = nil
        settled[id] = nil
        if leader == id { leader = nil }
        if !cluster.remove(id) { windows.removeAll() }
    }

    /// Takes a window out, leaving it wherever it is. Its neighbours fill the space.
    func detach(_ id: CGWindowID) {
        forget(id)
        fillGaps()
    }

    /// A lone window isn't a cluster any more, so it keeps its size rather than filling the space.
    private func fillGaps() {
        if windows.count > 1 { push() }
        syncPanels()
    }

    func attach(_ window: AXWindow, size: Rect, at drop: Drop<CGWindowID>) {
        windows[window.id] = window
        written[window.id] = nil
        settled[window.id] = nil
        reconciled = []
        cluster.attach(window.id, size: size, at: drop)
        push()
        syncPanels()
        restack()
    }

    /// Puts a window back where the layout says it belongs.
    func restore(_ id: CGWindowID) {
        written[id] = nil
        push()
    }

    /// Records what a window actually ended up as after our last write.
    func settle(_ id: CGWindowID, at frame: Rect) {
        settled[id] = frame
    }

    private func push(except excluded: CGWindowID? = nil) {
        for (id, frame) in cluster.frames where id != excluded {
            guard let window = windows[id] else { continue }
            let previous = written[id]
            guard previous != frame else { continue }
            written[id] = frame
            writer(window).submit(
                window,
                frame: frame,
                setPosition: previous.map { $0.x != frame.x || $0.y != frame.y } ?? true,
                setSize: previous.map { $0.width != frame.width || $0.height != frame.height } ?? true
            )
        }
    }

    private func syncPanels() {
        let dividers = cluster.dividers
        while panels.count > dividers.count {
            panels.removeLast().close()
        }
        while panels.count < dividers.count {
            let panel = DividerPanel(
                divider: dividers[panels.count],
                onDrag: { [weak self] divider, delta in self?.moveDivider(divider, by: delta) ?? 0 },
                onEnd: { [weak self] in
                    self?.draggingDivider = false
                    self?.restack()
                },
                onBegin: { [weak self] in
                    self?.beginGesture()
                    self?.draggingDivider = true
                }
            )
            panels.append(panel)
            panel.orderFront(nil)
        }
        for (panel, divider) in zip(panels, dividers) {
            panel.divider = divider
            panel.place(divider.frame)
        }
    }

    private func moveDivider(_ divider: Divider, by delta: Double) -> Double {
        let moved = cluster.moveDivider(divider, by: delta)
        lastDivider = divider
        push()
        syncPanels()
        return moved
    }

    /// Raises the cluster's windows to the top of `order`, which runs front to back and starts
    /// with one of them. That window stays in front.
    func raise(order: [CGWindowID]) {
        let visible = order.filter { windows[$0] != nil }
        guard let front = visible.first, Set(order.prefix(visible.count)) != Set(visible) else { return }
        let others = visible.dropFirst().compactMap { windows[$0] }
        guard let frontWindow = windows[front] else { return }
        // Raising blocks on each app, so it can't happen on the main thread.
        raiseQueue.async { [weak self] in
            others.forEach { $0.raise() }
            frontWindow.raise()
            DispatchQueue.main.async { self?.restack() }
        }
    }

    /// Keeps dividers just above the cluster rather than floating over unrelated windows.
    func restack() {
        guard let front = frontmostWindow(of: Set(windows.keys)) else { return }
        for panel in panels {
            panel.order(.above, relativeTo: Int(front))
        }
    }
}
