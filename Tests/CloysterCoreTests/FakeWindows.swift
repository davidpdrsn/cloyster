import CloysterCore

final class FakeSurface: ClusterSurface {
    let handlers: DividerHandlers
    var dividers: [Divider] = []
    var isClosed = false

    init(handlers: DividerHandlers) {
        self.handlers = handlers
    }

    func show(_ dividers: [Divider]) { self.dividers = dividers }
    func restack(above front: WindowID) {}
    func close() { isClosed = true }

    func drag(_ divider: Divider, by delta: Double) {
        handlers.onBegin()
        _ = handlers.onDrag(divider, delta)
        handlers.onEnd()
    }
}

/// A window system where writes only land when a test says so.
final class FakeWindows: WindowSystem {
    struct Window {
        var frame: Rect
        var pid: Int32
        var minWidth = 0.0
        var minHeight = 0.0
        /// Mimics terminals, which snap to character cells relative to their current size.
        var step: Double?
        var isManageable = true
        var isMinimized = false
    }

    private struct Write {
        var id: WindowID
        var frame: Rect
        var setPosition: Bool
        var setSize: Bool
    }

    var windows: [WindowID: Window] = [:]
    /// Front to back.
    var order: [WindowID] = []
    var cursor: (x: Double, y: Double)? = (0, 0)
    var commandHeld = false
    var preview: Rect?
    var raises = 0
    /// Rearranges what's reported without moving anything, like Mission Control.
    var overview: ((WindowID, Rect) -> Rect)?
    private(set) var surfaces: [FakeSurface] = []
    private var pending: [Write] = []
    private var dragged: WindowID?
    private(set) lazy var manager = Manager(system: self)

    func add(_ id: WindowID, _ frame: Rect, step: Double? = nil, minWidth: Double = 0) {
        windows[id] = Window(frame: frame, pid: Int32(id), minWidth: minWidth, step: step)
        order.insert(id, at: 0)
    }

    func frame(_ id: WindowID) -> Rect { windows[id]!.frame }

    var liveSurfaces: [FakeSurface] { surfaces.filter { !$0.isClosed } }

    // MARK: WindowSystem

    func frames(of ids: [WindowID]) -> [WindowID: Rect] {
        ids.reduce(into: [:]) { result, id in
            result[id] = windows[id].map { overview?(id, $0.frame) ?? $0.frame }
        }
    }

    func normalWindows() -> [WindowInfo] {
        order.compactMap { id in
            guard let window = windows[id], !window.isMinimized else { return nil }
            return WindowInfo(id: id, pid: window.pid, frame: window.frame)
        }
    }

    func isManageable(_ window: WindowInfo) -> Bool { windows[window.id]?.isManageable ?? false }

    func appName(of id: WindowID) -> String? { "app\(id)" }

    func write(_ id: WindowID, frame: Rect, setPosition: Bool, setSize: Bool) {
        if let i = pending.firstIndex(where: { $0.id == id }) {
            pending[i].frame = frame
            pending[i].setPosition = pending[i].setPosition || setPosition
            pending[i].setSize = pending[i].setSize || setSize
        } else {
            pending.append(Write(id: id, frame: frame, setPosition: setPosition, setSize: setSize))
        }
    }

    func isIdle(_ id: WindowID) -> Bool { !pending.contains { $0.id == id } }

    func raise(_ ids: [WindowID], completion: @escaping () -> Void) {
        raises += 1
        for id in ids {
            order.removeAll { $0 == id }
            order.insert(id, at: 0)
        }
        completion()
    }

    func makeSurface(_ handlers: DividerHandlers) -> ClusterSurface {
        let surface = FakeSurface(handlers: handlers)
        surfaces.append(surface)
        return surface
    }

    func showPreview(_ frame: Rect) { preview = frame }
    func hidePreview() { preview = nil }

    // MARK: Time passing

    var hasPendingWrites: Bool { !pending.isEmpty }

    func hasPendingWrite(for id: WindowID) -> Bool { pending.contains { $0.id == id } }

    /// Lands the oldest pending write.
    func deliverOne() {
        guard !pending.isEmpty else { return }
        let write = pending.removeFirst()
        guard var window = windows[write.id] else { return }
        if write.setPosition {
            window.frame.x = write.frame.x
            window.frame.y = write.frame.y
        }
        if write.setSize {
            window.frame.width = constrain(write.frame.width, from: window.frame.width, window.step, window.minWidth)
            window.frame.height = constrain(write.frame.height, from: window.frame.height, window.step, window.minHeight)
        }
        windows[write.id] = window
        manager.writeFinished(WriteResult(
            id: write.id, app: "app\(write.id)", target: write.frame, actual: window.frame, lag: 0
        ))
    }

    private func constrain(_ value: Double, from current: Double, _ step: Double?, _ minimum: Double) -> Double {
        let snapped = step.map { current + (((value - current) / $0).rounded() * $0) } ?? value
        return max(snapped, minimum)
    }

    /// Lets every write land and the manager react, until nothing changes.
    func settle() {
        for _ in 0..<20 {
            while hasPendingWrites { deliverOne() }
            manager.poll()
            if !hasPendingWrites { manager.poll() }
            if !hasPendingWrites { return }
        }
    }

    // MARK: The user

    /// Presses on a window's title bar. macOS brings it forward unless Cmd is held.
    func press(_ id: WindowID) {
        let frame = self.frame(id)
        cursor = (frame.x + frame.width / 2, frame.y + 14)
        if !commandHeld {
            order.removeAll { $0 == id }
            order.insert(id, at: 0)
        }
        dragged = id
        manager.mouseDown()
    }

    /// Moves the cursor, and macOS moves the pressed window with it.
    func move(toX x: Double, y: Double) {
        guard let cursor, let dragged, windows[dragged] != nil else { return }
        windows[dragged]!.frame.x += x - cursor.x
        windows[dragged]!.frame.y += y - cursor.y
        self.cursor = (x, y)
        manager.poll()
        manager.tickJoin()
    }

    func release() {
        manager.mouseUp()
        dragged = nil
    }

    /// Resizes a window the way dragging one of its edges does.
    func resize(_ id: WindowID, to frame: Rect) {
        cursor = (self.frame(id).x + 1, self.frame(id).y + 1)
        manager.mouseDown()
        windows[id]!.frame = frame
        manager.poll()
        manager.tickJoin()
        manager.mouseUp()
    }

    func close(_ id: WindowID) {
        windows[id] = nil
        order.removeAll { $0 == id }
    }

    /// Cmd+drags a window so the cursor ends up at a point, leaving writes pending.
    func commandDrag(_ id: WindowID, toX x: Double, y: Double) {
        commandHeld = true
        press(id)
        move(toX: x, y: y)
        release()
        commandHeld = false
    }
}
