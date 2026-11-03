import AppKit
import CloysterCore

/// The strip between two windows. Drawn by us, because the windows belong to other apps.
final class DividerPanel: NSPanel {
    var divider: Divider {
        didSet { gutter.axis = divider.axis }
    }
    private let gutter: GutterView

    init(divider: Divider, onDrag: @escaping (Divider, Double) -> Double, onEnd: @escaping () -> Void, onBegin: @escaping () -> Void) {
        self.divider = divider
        gutter = GutterView(axis: divider.axis)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        contentView = gutter
        gutter.onBegin = onBegin
        gutter.onEnd = onEnd
        gutter.onDrag = { [unowned self] delta in onDrag(self.divider, delta) }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Takes a frame in top-left coordinates.
    func place(_ rect: Rect) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        setFrame(
            NSRect(x: rect.x, y: primaryHeight - rect.y - rect.height, width: rect.width, height: rect.height),
            display: true
        )
    }
}

private final class GutterView: NSView {
    var axis: Axis {
        didSet { needsDisplay = true }
    }
    var onBegin: () -> Void = {}
    var onEnd: () -> Void = {}
    /// Asks to move the divider and returns how far it actually went.
    var onDrag: (Double) -> Double = { _ in 0 }

    private var start = NSPoint.zero
    private var moved = 0.0
    private var hovering = false {
        didSet { needsDisplay = true }
    }

    init(axis: Axis) {
        self.axis = axis
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    private var cursor: NSCursor { axis == .horizontal ? .resizeLeftRight : .resizeUpDown }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        cursor.set()
    }

    override func mouseMoved(with event: NSEvent) { cursor.set() }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        start = NSEvent.mouseLocation
        moved = 0
        onBegin()
    }

    override func mouseDragged(with event: NSEvent) {
        let location = NSEvent.mouseLocation
        let total = axis == .horizontal ? location.x - start.x : start.y - location.y
        moved += onDrag(total - moved)
    }

    override func mouseUp(with event: NSEvent) { onEnd() }

    override func draw(_ dirtyRect: NSRect) {
        let length = 36.0
        let thickness = 4.0
        let handle = axis == .horizontal
            ? NSRect(x: bounds.midX - thickness / 2, y: bounds.midY - length / 2, width: thickness, height: length)
            : NSRect(x: bounds.midX - length / 2, y: bounds.midY - thickness / 2, width: length, height: thickness)
        (hovering ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).setFill()
        NSBezierPath(roundedRect: handle, xRadius: thickness / 2, yRadius: thickness / 2).fill()
    }
}
