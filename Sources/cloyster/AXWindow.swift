import AppKit
import ApplicationServices
import CloysterCore

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Handle to another app's window.
struct AXWindow: @unchecked Sendable {
    let element: AXUIElement
    let id: CGWindowID
    let pid: pid_t
    let appName: String

    /// The standard windows of every regular app.
    static func all() -> [AXWindow] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .flatMap(windows)
    }

    /// A specific standard window, or nil if it isn't one we can manage.
    static func find(id: CGWindowID, pid: pid_t) -> AXWindow? {
        NSRunningApplication(processIdentifier: pid).flatMap { windows(of: $0).first { $0.id == id } }
    }

    private static func windows(of app: NSRunningApplication) -> [AXWindow] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        guard let elements: [AXUIElement] = attribute(appElement, kAXWindowsAttribute) else { return [] }
        return elements.compactMap { element in
            var id: CGWindowID = 0
            guard _AXUIElementGetWindow(element, &id) == .success, id != 0 else { return nil }
            let subrole: String? = attribute(element, kAXSubroleAttribute)
            guard subrole == kAXStandardWindowSubrole else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.5)
            return AXWindow(
                element: element,
                id: id,
                pid: app.processIdentifier,
                appName: app.localizedName ?? "pid \(app.processIdentifier)"
            )
        }
    }

    var title: String { attribute(element, kAXTitleAttribute) ?? "" }

    func frame() -> Rect? {
        guard
            let position: AXValue = attribute(element, kAXPositionAttribute),
            let size: AXValue = attribute(element, kAXSizeAttribute)
        else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position, .cgPoint, &point)
        AXValueGetValue(size, .cgSize, &extent)
        return Rect(x: point.x, y: point.y, width: extent.width, height: extent.height)
    }

    func raise() {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    func setPosition(of frame: Rect) {
        var point = CGPoint(x: frame.x, y: frame.y)
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    func setSize(of frame: Rect) {
        var size = CGSize(width: frame.width, height: frame.height)
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }
}

private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}

/// Some apps animate or slow down AX resizes while this is on, so it's off during a session.
final class EnhancedUserInterface {
    private static let name = "AXEnhancedUserInterface" as CFString
    private var disabled: [AXUIElement] = []

    func disable(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(app, Self.name, &value) == .success,
            value as? Bool == true
        else { return }
        AXUIElementSetAttributeValue(app, Self.name, kCFBooleanFalse)
        disabled.append(app)
    }

    func restore() {
        for app in disabled {
            AXUIElementSetAttributeValue(app, Self.name, kCFBooleanTrue)
        }
    }
}

/// Current frames from the window server, which avoids a round trip through each app.
/// Windows that no longer exist are missing from the result.
func windowServerFrames(_ ids: [CGWindowID]) -> [CGWindowID: Rect] {
    var pointers = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
    guard
        let array = CFArrayCreate(nil, &pointers, pointers.count, nil),
        let infos = CGWindowListCreateDescriptionFromArray(array) as? [[CFString: Any]]
    else { return [:] }
    var result: [CGWindowID: Rect] = [:]
    for info in infos {
        guard
            let id = info[kCGWindowNumber] as? CGWindowID,
            let bounds = info[kCGWindowBounds],
            let rect = CGRect(dictionaryRepresentation: bounds as! CFDictionary)
        else { continue }
        result[id] = Rect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }
    return result
}

/// The frontmost of `ids`, by on-screen stacking order.
func frontmostWindow(of ids: Set<CGWindowID>) -> CGWindowID? {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]] else {
        return nil
    }
    return infos.lazy.compactMap { $0[kCGWindowNumber] as? CGWindowID }.first(where: ids.contains)
}

struct WindowHit {
    let id: CGWindowID
    let pid: pid_t
    let frame: Rect
}

/// Visible normal windows, front to back, leaving out our own.
func normalWindows() -> [WindowHit] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]] else {
        return []
    }
    let ownPID = ProcessInfo.processInfo.processIdentifier
    return infos.compactMap { info in
        guard
            info[kCGWindowLayer] as? Int == 0,
            let id = info[kCGWindowNumber] as? CGWindowID,
            let pid = info[kCGWindowOwnerPID] as? pid_t, pid != ownPID,
            let bounds = info[kCGWindowBounds],
            let rect = CGRect(dictionaryRepresentation: bounds as! CFDictionary)
        else { return nil }
        return WindowHit(
            id: id, pid: pid,
            frame: Rect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        )
    }
}

/// The frontmost normal window at a point.
func topWindow(atX x: Double, y: Double, excluding excluded: CGWindowID? = nil) -> WindowHit? {
    normalWindows().first { $0.id != excluded && $0.frame.contains(x: x, y: y) }
}
