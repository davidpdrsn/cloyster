import AppKit
import CloysterCore

/// Owns every cluster, and handles the gestures that create and change them.
final class Manager {
    private struct PendingDrop {
        let window: AXWindow
        let frame: Rect
        let drop: Drop<CGWindowID>
    }

    /// A Cmd+drag. It only counts once the window actually moves, so Cmd+click does nothing.
    private struct JoinGesture {
        let window: AXWindow
        let start: Rect
        var moved = false
        var pending: PendingDrop?
        /// Windows hovered over so far, to avoid asking their apps again on every tick.
        var seen: [CGWindowID: AXWindow?] = [:]
    }

    private(set) var controllers: [Controller] = []
    private var writers: [pid_t: Writer] = [:]
    private let enhancedUserInterface = EnhancedUserInterface()
    private let stats = Stats()
    private let preview = JoinPreview()
    private var dragTimer: Timer?
    private var joinTimer: Timer?
    private var idleTimer: Timer?
    private var join: JoinGesture?
    /// The window under the cursor when the mouse went down, until a join claims it.
    private var pressed: WindowHit?
    private var lastFront: CGWindowID?

    func start() {
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in self?.mouseDown() }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in self?.mouseUp() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.raiseFrontCluster() }
        idleTimer = schedule(interval: 0.2) { [weak self] in self?.poll() }
    }

    func stop() {
        enhancedUserInterface.restore()
        print(stats.report(coalesced: writers.values.reduce(0) { $0 + $1.coalesced }))
    }

    @discardableResult
    func add(_ cluster: Cluster<CGWindowID>, windows: [AXWindow]) -> Controller {
        let controller = Controller(cluster: cluster, windows: windows, stats: stats) { [weak self] window in
            self?.writer(for: window) ?? Writer(label: "orphan") { _ in }
        }
        controllers.append(controller)
        controller.start()
        return controller
    }

    func dissolve(_ controller: Controller) {
        controller.close()
        controllers.removeAll { $0 === controller }
    }

    func dissolveAll() {
        controllers.forEach(dissolve)
    }

    private func controller(containing id: CGWindowID) -> Controller? {
        controllers.first { $0.windows[id] != nil }
    }

    private func writer(for window: AXWindow) -> Writer {
        if let writer = writers[window.pid] { return writer }
        enhancedUserInterface.disable(pid: window.pid)
        let app = "\(window.appName) (\(window.pid))"
        let writer = Writer(label: "\(window.pid)") { [weak self] completion in
            self?.record(completion, app: app)
        }
        writers[window.pid] = writer
        return writer
    }

    private func record(_ completion: Writer.Completion, app: String) {
        var entry = stats.apps[app, default: Stats.App()]
        entry.writes += 1
        entry.lagMilliseconds.append(completion.lag * 1000)
        if let actual = completion.actual {
            controller(containing: completion.id)?.settle(completion.id, at: actual)
            if actual.differs(from: completion.target) { entry.refused += 1 }
        }
        stats.apps[app] = entry
    }

    private func schedule(interval: TimeInterval, _ action: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in action() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func poll() {
        let gesture = dragTimer != nil
        if gesture { beginJoinIfCommandHeld() }
        controllers.forEach { $0.poll(gesture: gesture) }
        sweep()
        if !gesture { raiseFrontCluster() }
    }

    /// Brings a whole cluster forward when one of its windows reaches the front. Works from the
    /// stacking order, so it doesn't matter whether that was a click, Cmd+Tab or anything else.
    private func raiseFrontCluster() {
        guard join == nil else { return }
        let order = normalWindows().map(\.id)
        guard let front = order.first, front != lastFront else { return }
        lastFront = front
        controller(containing: front)?.raise(order: order)
        controllers.forEach { $0.restack() }
    }

    /// A cluster needs at least two windows. The last one is simply left where it is.
    private func sweep() {
        controllers.filter { $0.windows.count < 2 }.forEach(dissolve)
    }

    private func mouseDown() {
        controllers.forEach { $0.beginGesture() }
        pressed = cursor.flatMap { topWindow(atX: $0.x, y: $0.y) }
        dragTimer?.invalidate()
        dragTimer = schedule(interval: 1.0 / 120) { [weak self] in self?.poll() }
        beginJoinIfCommandHeld()
    }

    private func mouseUp() {
        guard dragTimer != nil else { return }
        // Before the join, which would otherwise look like the user moving the joined window.
        poll()
        if join != nil {
            tickJoin()
            finishJoin()
        }
        pressed = nil
        dragTimer?.invalidate()
        dragTimer = nil
        controllers.forEach { $0.endGesture() }
        raiseFrontCluster()
    }

    private var cursor: CGPoint? { CGEvent(source: nil)?.location }

    /// Reads the keyboard rather than mouse events, because tools that rewrite mouse input can
    /// drop the flag, and Cmd may go down after the drag has started. Those rewritten events can
    /// clear the session's flags too, so the hardware state counts as well.
    private var commandHeld: Bool {
        [.combinedSessionState, .hidSystemState].contains {
            CGEventSource.flagsState($0).contains(.maskCommand)
        }
    }

    private func beginJoinIfCommandHeld() {
        guard join == nil, commandHeld, let hit = pressed else { return }
        pressed = nil
        guard let window = AXWindow.find(id: hit.id, pid: hit.pid) else { return }
        controller(containing: hit.id)?.isPaused = true
        join = JoinGesture(window: window, start: hit.frame)
        joinTimer = schedule(interval: 1.0 / 30) { [weak self] in self?.tickJoin() }
    }

    private func tickJoin() {
        guard var gesture = join else { return }
        let id = gesture.window.id
        guard let frame = windowServerFrames([id])[id] else { return endJoin() }
        if !gesture.moved {
            // Cmd+resizing isn't a join, so it goes back to being an ordinary gesture.
            if frame.width != gesture.start.width || frame.height != gesture.start.height {
                return endJoin()
            }
            gesture.moved = frame.x != gesture.start.x || frame.y != gesture.start.y
        }
        if gesture.moved {
            gesture.pending = commandHeld ? findDrop(&gesture) : nil
            if let pending = gesture.pending, let rect = destination(pending, gesture) {
                preview.show(rect)
            } else {
                preview.orderOut(nil)
            }
        }
        join = gesture
    }

    private func findDrop(_ gesture: inout JoinGesture) -> PendingDrop? {
        guard let cursor, let hit = topWindow(atX: cursor.x, y: cursor.y, excluding: gesture.window.id) else {
            return nil
        }
        guard
            let window = joinableWindow(hit, &gesture),
            let drop = cluster(of: hit).drop(x: cursor.x, y: cursor.y, over: hit.id)
        else { return nil }
        return PendingDrop(window: window, frame: hit.frame, drop: drop)
    }

    private func joinableWindow(_ hit: WindowHit, _ gesture: inout JoinGesture) -> AXWindow? {
        if let window = controller(containing: hit.id)?.windows[hit.id] { return window }
        if let seen = gesture.seen[hit.id] { return seen }
        let window = AXWindow.find(id: hit.id, pid: hit.pid)
        gesture.seen.updateValue(window, forKey: hit.id)
        return window
    }

    private func cluster(of hit: WindowHit) -> Cluster<CGWindowID> {
        controller(containing: hit.id)?.cluster ?? Cluster(root: .window(hit.id), frame: hit.frame)
    }

    private func destination(_ pending: PendingDrop, _ gesture: JoinGesture) -> Rect? {
        let hit = WindowHit(id: pending.window.id, pid: pending.window.pid, frame: pending.frame)
        return cluster(of: hit).preview(gesture.window.id, size: gesture.start, at: pending.drop)
    }

    private func finishJoin() {
        guard let gesture = join else { return }
        let id = gesture.window.id
        let source = controller(containing: id)
        endJoin()
        guard gesture.moved else { return }

        if let pending = gesture.pending {
            source?.detach(id)
            let target = controller(containing: pending.window.id) ?? add(
                Cluster(root: .window(pending.window.id), frame: pending.frame),
                windows: [pending.window]
            )
            target.attach(gesture.window, size: gesture.start, at: pending.drop)
        } else if commandHeld {
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
        joinTimer?.invalidate()
        joinTimer = nil
        preview.orderOut(nil)
    }
}
