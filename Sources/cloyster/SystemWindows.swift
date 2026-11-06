import AppKit
import CloysterCore

/// The real windows on this Mac.
final class SystemWindows: WindowSystem {
    /// Receives the results of writes, on the main thread.
    var onWrite: (WriteResult) -> Void = { _ in }
    private var known: [WindowID: AXWindow] = [:]
    private var writers: [pid_t: Writer] = [:]
    private let enhancedUserInterface = EnhancedUserInterface()
    private let preview = JoinPreview()
    // Raising blocks on each app, so it can't happen on the main thread.
    private let raiseQueue = DispatchQueue(label: "cloyster.raise", qos: .userInteractive)

    func register(_ windows: [AXWindow]) {
        windows.forEach { known[$0.id] = $0 }
    }

    var coalesced: Int { writers.values.reduce(0) { $0 + $1.coalesced } }

    func restore() {
        enhancedUserInterface.restore()
    }

    var cursor: (x: Double, y: Double)? {
        CGEvent(source: nil).map { ($0.location.x, $0.location.y) }
    }

    /// Reads the keyboard rather than mouse events, because tools that rewrite mouse input can
    /// drop the flag, and Cmd may go down after the drag has started. Those rewritten events can
    /// clear the session's flags too, so the hardware state counts as well. Cmd has to be on its
    /// own, because combinations like Opt+Cmd belong to other tools.
    var commandHeld: Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
            .union(CGEventSource.flagsState(.hidSystemState))
        return flags.contains(.maskCommand)
            && flags.isDisjoint(with: [.maskAlternate, .maskControl, .maskShift])
    }

    func frames(of ids: [WindowID]) -> [WindowID: Rect] {
        windowServerFrames(ids)
    }

    func normalWindows() -> [WindowInfo] {
        cloyster.normalWindows()
    }

    func isManageable(_ window: WindowInfo) -> Bool {
        if known[window.id] != nil { return true }
        guard let found = AXWindow.find(id: window.id, pid: window.pid) else { return false }
        known[window.id] = found
        return true
    }

    func appName(of id: WindowID) -> String? {
        known[id]?.appName
    }

    func write(_ id: WindowID, frame: Rect, setPosition: Bool, setSize: Bool) {
        guard let window = known[id] else { return }
        writer(for: window).submit(window, frame: frame, setPosition: setPosition, setSize: setSize)
    }

    func isIdle(_ id: WindowID) -> Bool {
        known[id].flatMap { writers[$0.pid] }?.isIdle ?? true
    }

    private func writer(for window: AXWindow) -> Writer {
        if let writer = writers[window.pid] { return writer }
        enhancedUserInterface.disable(pid: window.pid)
        let app = "\(window.appName) (\(window.pid))"
        let writer = Writer(label: "\(window.pid)") { [weak self] completion in
            self?.onWrite(WriteResult(
                id: completion.id, app: app, target: completion.target,
                actual: completion.actual, lag: completion.lag
            ))
        }
        writers[window.pid] = writer
        return writer
    }

    func raise(_ ids: [WindowID], completion: @escaping () -> Void) {
        let windows = ids.compactMap { known[$0] }
        raiseQueue.async {
            windows.forEach { $0.raise() }
            DispatchQueue.main.async(execute: completion)
        }
    }

    func makeSurface(_ handlers: DividerHandlers) -> ClusterSurface {
        PanelSurface(handlers: handlers)
    }

    func showPreview(_ frame: Rect) {
        preview.show(frame)
    }

    func hidePreview() {
        preview.orderOut(nil)
    }
}
