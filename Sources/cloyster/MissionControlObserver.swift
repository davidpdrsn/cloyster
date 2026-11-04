import AppKit
import ApplicationServices

/// Reports Mission Control opening and closing, which the Dock announces through Accessibility.
final class MissionControlObserver {
    private static let opening = ["AXExposeShowAllWindows", "AXExposeShowFrontWindows", "AXExposeShowDesktop"]
    private static let closing = "AXExposeExit"

    private let onChange: (Bool) -> Void
    private var observer: AXObserver?

    init?(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        guard
            let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        let callback: AXObserverCallback = { _, _, notification, context in
            guard let context else { return }
            let observer = Unmanaged<MissionControlObserver>.fromOpaque(context).takeUnretainedValue()
            observer.onChange(notification as String != MissionControlObserver.closing)
        }
        guard AXObserverCreate(dock.processIdentifier, callback, &observer) == .success, let observer else {
            return nil
        }
        let element = AXUIElementCreateApplication(dock.processIdentifier)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.opening + [Self.closing] {
            AXObserverAddNotification(observer, element, name as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}
