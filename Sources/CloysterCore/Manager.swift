/// Owns every cluster, and handles the gestures that create and change them.
public final class Manager {
    private struct PendingDrop {
        let target: WindowInfo
        let drop: Drop<WindowID>
    }

    /// A Cmd+drag. It only counts once the window actually moves, so Cmd+click does nothing.
    private struct JoinGesture {
        let window: WindowInfo
        var moved = false
        var pending: PendingDrop?
        /// Windows hovered over so far, to avoid asking their apps again on every tick.
        var seen: [WindowID: Bool] = [:]
    }

    public private(set) var controllers: [Controller] = []
    public let stats = Stats()
    private let system: WindowSystem
    private var mouseIsDown = false
    private var join: JoinGesture?
    /// The window under the cursor when the mouse went down, until a join claims it.
    private var pressed: WindowInfo?
    private var lastFront: WindowID?
    private var isSuspended = false

    public init(system: WindowSystem) {
        self.system = system
    }

    @discardableResult
    public func add(_ cluster: Cluster<WindowID>) -> Controller {
        let controller = Controller(cluster: cluster, system: system, stats: stats)
        controllers.append(controller)
        controller.start()
        return controller
    }

    public func dissolve(_ controller: Controller) {
        controller.close()
        controllers.removeAll { $0 === controller }
    }

    public func dissolveAll() {
        controllers.forEach(dissolve)
    }

    private func controller(containing id: WindowID) -> Controller? {
        controllers.first { $0.windows.contains(id) }
    }

    public func writeFinished(_ result: WriteResult) {
        var entry = stats.apps[result.app, default: Stats.App()]
        entry.writes += 1
        entry.lagMilliseconds.append(result.lag * 1000)
        if let actual = result.actual {
            controller(containing: result.id)?.settle(result.id, at: actual)
            if actual.differs(from: result.target) { entry.refused += 1 }
        }
        stats.apps[result.app] = entry
    }

    /// Stops reacting to windows, for when the system rearranges them like Mission Control does.
    public func suspend() {
        isSuspended = true
        endJoin()
        pressed = nil
        mouseIsDown = false
        controllers.forEach { $0.endGesture() }
    }

    public func resume() {
        isSuspended = false
    }

    /// Call regularly, and much more often while the mouse is down.
    public func poll() {
        guard !isSuspended else { return }
        if mouseIsDown { beginJoinIfCommandHeld() }
        controllers.forEach { $0.poll(gesture: mouseIsDown) }
        sweep()
        if !mouseIsDown { raiseFrontCluster() }
    }

    /// Brings a whole cluster forward when one of its windows reaches the front. Works from the
    /// stacking order, so it doesn't matter whether that was a click, Cmd+Tab or anything else.
    public func raiseFrontCluster() {
        guard join == nil, !isSuspended else { return }
        let order = system.normalWindows().map(\.id)
        guard let front = order.first, front != lastFront else { return }
        lastFront = front
        controller(containing: front)?.raise(order: order)
        controllers.forEach { $0.restack() }
    }

    /// A cluster needs at least two windows. The last one is simply left where it is.
    private func sweep() {
        controllers.filter { $0.windows.count < 2 }.forEach(dissolve)
    }

    public func mouseDown() {
        guard !isSuspended else { return }
        controllers.forEach { $0.beginGesture() }
        pressed = system.cursor.flatMap(topWindow)
        mouseIsDown = true
        beginJoinIfCommandHeld()
    }

    public func mouseUp() {
        guard mouseIsDown else { return }
        // Before the join, which would otherwise look like the user moving the joined window.
        poll()
        if join != nil {
            tickJoin()
            finishJoin()
        }
        pressed = nil
        mouseIsDown = false
        controllers.forEach { $0.endGesture() }
        raiseFrontCluster()
    }

    private func topWindow(at point: (x: Double, y: Double)) -> WindowInfo? {
        system.normalWindows().first { $0.frame.contains(x: point.x, y: point.y) }
    }

    private func beginJoinIfCommandHeld() {
        guard join == nil, system.commandHeld, let hit = pressed else { return }
        pressed = nil
        guard system.isManageable(hit) else { return }
        controller(containing: hit.id)?.isPaused = true
        join = JoinGesture(window: hit)
    }

    /// Call regularly while the mouse is down.
    public func tickJoin() {
        guard var gesture = join else { return }
        let id = gesture.window.id
        let start = gesture.window.frame
        guard let frame = system.frames(of: [id])[id] else { return endJoin() }
        if !gesture.moved {
            // Cmd+resizing isn't a join, so it goes back to being an ordinary gesture.
            if frame.width != start.width || frame.height != start.height {
                return endJoin()
            }
            gesture.moved = frame.x != start.x || frame.y != start.y
        }
        if gesture.moved {
            gesture.pending = system.commandHeld ? findDrop(&gesture) : nil
            if let pending = gesture.pending, let rect = destination(pending, gesture) {
                system.showPreview(rect)
            } else {
                system.hidePreview()
            }
        }
        join = gesture
    }

    private func findDrop(_ gesture: inout JoinGesture) -> PendingDrop? {
        guard
            let cursor = system.cursor,
            let hit = system.normalWindows().first(where: {
                $0.id != gesture.window.id && $0.frame.contains(x: cursor.x, y: cursor.y)
            }),
            isJoinable(hit, &gesture),
            let drop = cluster(of: hit).drop(x: cursor.x, y: cursor.y, over: hit.id)
        else { return nil }
        return PendingDrop(target: hit, drop: drop)
    }

    private func isJoinable(_ hit: WindowInfo, _ gesture: inout JoinGesture) -> Bool {
        if controller(containing: hit.id) != nil { return true }
        if let seen = gesture.seen[hit.id] { return seen }
        let joinable = system.isManageable(hit)
        gesture.seen[hit.id] = joinable
        return joinable
    }

    private func cluster(of hit: WindowInfo) -> Cluster<WindowID> {
        controller(containing: hit.id)?.cluster ?? Cluster(root: .window(hit.id), frame: hit.frame)
    }

    private func destination(_ pending: PendingDrop, _ gesture: JoinGesture) -> Rect? {
        cluster(of: pending.target).preview(gesture.window.id, size: gesture.window.frame, at: pending.drop)
    }

    private func finishJoin() {
        guard let gesture = join else { return }
        let id = gesture.window.id
        let source = controller(containing: id)
        endJoin()
        guard gesture.moved else { return }

        if let pending = gesture.pending {
            source?.detach(id)
            let target = controller(containing: pending.target.id)
                ?? add(Cluster(root: .window(pending.target.id), frame: pending.target.frame))
            target.attach(id, size: gesture.window.frame, at: pending.drop)
        } else if system.commandHeld {
            source?.detach(id)
        } else {
            source?.restore(id)
        }
        sweep()
    }

    private func endJoin() {
        if let id = join?.window.id {
            controller(containing: id)?.isPaused = false
        }
        join = nil
        system.hidePreview()
    }
}
