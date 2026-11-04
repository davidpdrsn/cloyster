import AppKit
import CloysterCore

/// Feeds real mouse events and timers into the manager.
final class Driver {
    let system = SystemWindows()
    let manager: Manager
    private var idleTimer: Timer?
    private var dragTimer: Timer?
    private var joinTimer: Timer?

    init() {
        manager = Manager(system: system)
        system.onWrite = { [manager] in manager.writeFinished($0) }
    }

    func start() {
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in self?.mouseDown() }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in self?.mouseUp() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.manager.raiseFrontCluster() }
        idleTimer = schedule(interval: 0.2) { [weak self] in self?.manager.poll() }
    }

    func stop() {
        system.restore()
        print(manager.stats.report(coalesced: system.coalesced))
    }

    private func schedule(interval: TimeInterval, _ action: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in action() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func mouseDown() {
        manager.mouseDown()
        dragTimer?.invalidate()
        joinTimer?.invalidate()
        dragTimer = schedule(interval: 1.0 / 120) { [weak self] in self?.manager.poll() }
        joinTimer = schedule(interval: 1.0 / 30) { [weak self] in self?.manager.tickJoin() }
    }

    private func mouseUp() {
        manager.mouseUp()
        dragTimer?.invalidate()
        joinTimer?.invalidate()
        dragTimer = nil
        joinTimer = nil
    }
}
