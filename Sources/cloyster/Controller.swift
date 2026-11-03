import AppKit
import CloysterCore

/// Keeps real windows in step with a cluster.
///
/// While the mouse is down the first window to change becomes the leader and everything else
/// follows it. The leader is never written to mid-gesture because the user is driving it.
final class Controller {
    private var cluster: Cluster<CGWindowID>
    private var windows: [CGWindowID: AXWindow]
    private var writers: [pid_t: Writer] = [:]
    private var panels: [DividerPanel] = []
    private let enhancedUserInterface = EnhancedUserInterface()
    private var stats = Stats()

    /// Last frame we asked for, or saw the user set, per window.
    private var written: [CGWindowID: Rect] = [:]
    /// What windows settled on after our writes, which can differ if they refuse a size.
    private var settled: [CGWindowID: Rect] = [:]
    private var leader: CGWindowID?
    private var dragTimer: Timer?
    private var idleTimer: Timer?
    private var draggingDivider = false
    private var lastDivider: Divider?
    /// Windows whose refused size has been adopted since the last gesture. Each gets one turn, so
    /// two windows that snap to different sizes can't chase each other forever.
    private var reconciled: Set<CGWindowID> = []

    init(cluster: Cluster<CGWindowID>, windows: [AXWindow]) {
        self.cluster = cluster
        self.windows = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
    }

    func start() {
        for pid in Set(windows.values.map(\.pid)) {
            enhancedUserInterface.disable(pid: pid)
            let name = windows.values.first { $0.pid == pid }?.appName ?? ""
            writers[pid] = Writer(label: "\(pid)") { [weak self] completion in
                self?.record(completion, app: "\(name) (\(pid))")
            }
        }
        push()
        syncPanels()
        restack()

        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in self?.mouseDown() }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in self?.mouseUp() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.restack() }

        idleTimer = schedule(interval: 0.2)
    }

    func stop() {
        enhancedUserInterface.restore()
        let coalesced = writers.values.reduce(0) { $0 + $1.coalesced }
        print(stats.report(coalesced: coalesced))
    }

    private func schedule(interval: TimeInterval) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func mouseDown() {
        leader = nil
        beginGesture()
        dragTimer?.invalidate()
        dragTimer = schedule(interval: 1.0 / 120)
    }

    private func beginGesture() {
        lastDivider = nil
        reconciled = []
    }

    private func mouseUp() {
        guard dragTimer != nil else { return }
        poll()
        dragTimer?.invalidate()
        dragTimer = nil
        if leader != nil {
            leader = nil
            push()
            syncPanels()
        }
        restack()
    }

    private func poll() {
        guard !draggingDivider else { return }
        let current = windowServerFrames(Array(windows.keys))
        removeClosedWindows(current)
        guard !windows.isEmpty else { return }

        let gesture = dragTimer != nil
        if !gesture {
            guard writers.values.allSatisfy(\.isIdle) else { return }
            reconcile()
        }

        let frames = cluster.frames
        if let leader {
            sampleDrift(current, frames, leader: leader)
        }
        let changed = leader ?? windows.keys.first { id in
            guard let frame = current[id], let expected = frames[id] else { return false }
            return differs(frame, expected) && settled[id].map { differs(frame, $0) } ?? true
        }
        guard let changed, let frame = current[changed], let expected = frames[changed] else { return }
        guard differs(frame, expected) else { return }

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
            !reconciled.contains(id) && written[id].map { differs(actual, $0) } ?? false
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
        for id in closed {
            windows[id] = nil
            written[id] = nil
            settled[id] = nil
            if leader == id { leader = nil }
            if !cluster.remove(id) { windows.removeAll() }
        }
        if windows.count < 2 {
            print("cluster dissolved: fewer than two windows left")
            stop()
            exit(0)
        }
        push()
        syncPanels()
    }

    private func push(except excluded: CGWindowID? = nil) {
        for (id, frame) in cluster.frames where id != excluded {
            guard let window = windows[id], let writer = writers[window.pid] else { continue }
            let previous = written[id]
            guard previous != frame else { continue }
            written[id] = frame
            writer.submit(
                window,
                frame: frame,
                setPosition: previous.map { $0.x != frame.x || $0.y != frame.y } ?? true,
                setSize: previous.map { $0.width != frame.width || $0.height != frame.height } ?? true
            )
        }
    }

    private func record(_ completion: Writer.Completion, app: String) {
        var entry = stats.apps[app, default: Stats.App()]
        entry.writes += 1
        entry.lagMilliseconds.append(completion.lag * 1000)
        if let actual = completion.actual {
            settled[completion.id] = actual
            if differs(actual, completion.target) { entry.refused += 1 }
        }
        stats.apps[app] = entry
    }

    private func differs(_ a: Rect, _ b: Rect) -> Bool {
        abs(a.x - b.x) > 0.5 || abs(a.y - b.y) > 0.5
            || abs(a.width - b.width) > 0.5 || abs(a.height - b.height) > 0.5
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

    /// Keeps dividers just above the cluster rather than floating over unrelated windows.
    private func restack() {
        guard let front = frontmostWindow(of: Set(windows.keys)) else { return }
        for panel in panels {
            panel.order(.above, relativeTo: Int(front))
        }
    }
}
