import CoreGraphics
import CloysterCore
import Foundation

/// Applies frames to one app's windows off the main thread.
///
/// AX writes block until the target app's main thread responds, so each app gets its own queue.
/// Only the newest frame per window is kept, which stops a slow app building up a backlog.
final class Writer {
    struct Completion {
        let id: CGWindowID
        let sequence: Int
        let target: Rect
        /// What the window ended up as. Only read for the newest frame of a window.
        let actual: Rect?
        let lag: TimeInterval
    }

    private struct Job {
        var window: AXWindow
        var frame: Rect
        var setPosition: Bool
        var setSize: Bool
        var sequence: Int
        var submitted: Date
    }

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: [CGWindowID: Job] = [:]
    private var draining = false
    private var sequence = 0
    private var newest: [CGWindowID: Int] = [:]
    private let onComplete: (Completion) -> Void
    private(set) var coalesced = 0

    init(label: String, onComplete: @escaping (Completion) -> Void) {
        queue = DispatchQueue(label: "cloyster.writer.\(label)", qos: .userInteractive)
        self.onComplete = onComplete
    }

    /// True once every submitted frame has been applied and reported. Main thread only.
    var isIdle: Bool { newest.isEmpty }

    func submit(_ window: AXWindow, frame: Rect, setPosition: Bool, setSize: Bool) {
        sequence += 1
        newest[window.id] = sequence
        let job = Job(
            window: window, frame: frame, setPosition: setPosition, setSize: setSize,
            sequence: sequence, submitted: Date()
        )
        lock.lock()
        defer { lock.unlock() }
        if let replaced = pending[window.id] {
            coalesced += 1
            pending[window.id] = Job(
                window: job.window, frame: job.frame,
                setPosition: job.setPosition || replaced.setPosition,
                setSize: job.setSize || replaced.setSize,
                sequence: job.sequence, submitted: replaced.submitted
            )
        } else {
            pending[window.id] = job
        }
        if !draining {
            draining = true
            queue.async { self.drain() }
        }
    }

    private func drain() {
        while let job = next() {
            if job.setPosition { job.window.setPosition(of: job.frame) }
            if job.setSize { job.window.setSize(of: job.frame) }
            let actual = hasPending(job.window.id) ? nil : job.window.frame()
            let completion = Completion(
                id: job.window.id, sequence: job.sequence, target: job.frame, actual: actual,
                lag: Date().timeIntervalSince(job.submitted)
            )
            DispatchQueue.main.async {
                if self.newest[completion.id] == completion.sequence {
                    self.newest[completion.id] = nil
                }
                self.onComplete(completion)
            }
        }
    }

    private func next() -> Job? {
        lock.lock()
        defer { lock.unlock() }
        guard let key = pending.keys.first else {
            draining = false
            return nil
        }
        return pending.removeValue(forKey: key)
    }

    private func hasPending(_ id: CGWindowID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending[id] != nil
    }
}
