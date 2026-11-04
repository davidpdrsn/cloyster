import Foundation

public typealias WindowID = UInt32

public struct WindowInfo: Equatable, Sendable {
    public var id: WindowID
    public var pid: Int32
    public var frame: Rect

    public init(id: WindowID, pid: Int32, frame: Rect) {
        self.id = id
        self.pid = pid
        self.frame = frame
    }
}

/// The outcome of a frame written with `WindowSystem.write`.
public struct WriteResult: Sendable {
    public var id: WindowID
    public var app: String
    public var target: Rect
    /// What the window ended up as. Only read for the newest frame of a window.
    public var actual: Rect?
    public var lag: TimeInterval

    public init(id: WindowID, app: String, target: Rect, actual: Rect?, lag: TimeInterval) {
        self.id = id
        self.app = app
        self.target = target
        self.actual = actual
        self.lag = lag
    }
}

public struct DividerHandlers {
    public var onBegin: () -> Void
    /// Asks to move a divider and returns how far it actually went.
    public var onDrag: (Divider, Double) -> Double
    public var onEnd: () -> Void
}

/// What a cluster draws on screen.
public protocol ClusterSurface: AnyObject {
    func show(_ dividers: [Divider])
    func restack(above front: WindowID)
    func close()
}

/// Everything the cluster logic needs from the outside world, so it can run without real windows.
public protocol WindowSystem: AnyObject {
    var cursor: (x: Double, y: Double)? { get }
    var commandHeld: Bool { get }

    /// Current frames. Windows that no longer exist are missing from the result.
    func frames(of ids: [WindowID]) -> [WindowID: Rect]
    /// Visible normal windows, front to back, leaving out our own.
    func normalWindows() -> [WindowInfo]
    /// Whether this is a window we're able to control.
    func isManageable(_ window: WindowInfo) -> Bool
    func appName(of id: WindowID) -> String?

    /// Applies a frame some time later, then reports it through `Manager.writeFinished`.
    func write(_ id: WindowID, frame: Rect, setPosition: Bool, setSize: Bool)
    /// True once every frame written to a window's app has been applied and reported.
    func isIdle(_ id: WindowID) -> Bool
    /// Raises windows in order, so the last one ends up in front.
    func raise(_ ids: [WindowID], completion: @escaping () -> Void)

    func makeSurface(_ handlers: DividerHandlers) -> ClusterSurface
    func showPreview(_ frame: Rect)
    func hidePreview()
}
