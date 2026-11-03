import AppKit
import ApplicationServices
import CloysterCore

let usage = """
    usage:
      cloyster list
      cloyster run <layout> [--frame x,y,width,height]

    A layout nests h(...) for side by side and v(...) for stacked. Leaves are window IDs from
    `cloyster list`, or app names, which take that app's next unused window:

      cloyster run 'h(Safari,v(Terminal,Notes))'

    Ctrl-C stops and prints lag statistics.
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func parseFrame(_ text: String) -> Rect? {
    let parts = text.split(separator: ",").compactMap { Double($0) }
    guard parts.count == 4 else { return nil }
    return Rect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
}

/// Most of the main screen, in top-left coordinates.
func defaultFrame() -> Rect {
    guard let screen = NSScreen.main, let primary = NSScreen.screens.first else {
        fail("no screen found")
    }
    let visible = screen.visibleFrame.insetBy(dx: 60, dy: 60)
    return Rect(
        x: visible.minX,
        y: primary.frame.height - visible.maxY,
        width: visible.width,
        height: visible.height
    )
}

func list() {
    for window in AXWindow.all() {
        print("\(window.id)\t\(window.appName)\t\(window.title)")
    }
}

func run(layout: String, frame: Rect) -> Never {
    guard let spec = Node<String>.parse(layout) else { fail("invalid layout: \(layout)") }
    var available = AXWindow.all()
    var chosen: [AXWindow] = []
    let root = spec.mapWindows { (leaf: String) -> CGWindowID? in
        let isMatch: (AXWindow) -> Bool = { window in
            if let id = CGWindowID(leaf) { return window.id == id }
            return window.appName.caseInsensitiveCompare(leaf) == .orderedSame
        }
        guard let index = available.firstIndex(where: isMatch) else {
            fail("no available window for \(leaf)")
        }
        let window = available.remove(at: index)
        chosen.append(window)
        return window.id
    }
    guard let root else { fail("invalid layout: \(layout)") }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = Controller(cluster: Cluster(root: root, frame: frame), windows: chosen)
    controller.start()

    var sources: [DispatchSourceSignal] = []
    for number in [SIGINT, SIGTERM] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
            controller.stop()
            exit(0)
        }
        source.resume()
        sources.append(source)
    }
    withExtendedLifetime(sources) { app.run() }
    exit(0)
}

guard AXIsProcessTrusted() else {
    fail("grant Accessibility access to your terminal in System Settings > Privacy & Security")
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "list":
    list()
case "run":
    guard arguments.count >= 2 else { fail(usage) }
    var frame: Rect?
    if let flag = arguments.firstIndex(of: "--frame") {
        guard flag + 1 < arguments.count, let parsed = parseFrame(arguments[flag + 1]) else { fail(usage) }
        frame = parsed
    }
    run(layout: arguments[1], frame: frame ?? defaultFrame())
default:
    fail(usage)
}
