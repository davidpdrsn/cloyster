import AppKit

// A throwaway window for testing cloyster without touching real apps.
//
//   demo-window <title> [--frame x,y,width,height] [--min width,height] [--step points] [--busy ms]
//
// --step mimics terminals snapping to character cells, and --busy mimics an app with a slow main
// thread by blocking it for that long, every 50ms. Prints the window ID on startup.

let arguments = CommandLine.arguments

func value(_ flag: String) -> String? {
    arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
}

func numbers(_ flag: String) -> [Double]? {
    value(flag).map { $0.split(separator: ",").compactMap { Double($0) } }
}

let title = arguments.count > 1 ? arguments[1] : "demo"
let frame = numbers("--frame") ?? [200, 200, 500, 400]
let primaryHeight = NSScreen.screens.first?.frame.height ?? 0

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let window = NSWindow(
    contentRect: NSRect(x: frame[0], y: primaryHeight - frame[1] - frame[3], width: frame[2], height: frame[3]),
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered,
    defer: false
)
window.title = title
window.isReleasedWhenClosed = false
window.backgroundColor = NSColor(hue: CGFloat(abs(title.hashValue) % 360) / 360, saturation: 0.35, brightness: 0.9, alpha: 1)
if let minimum = numbers("--min") {
    window.minSize = NSSize(width: minimum[0], height: minimum[1])
}
if let step = numbers("--step")?.first {
    window.resizeIncrements = NSSize(width: step, height: step)
}
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

if let busy = numbers("--busy")?.first {
    Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
        Thread.sleep(forTimeInterval: busy / 1000)
    }
}

print(window.windowNumber)
fflush(stdout)
app.run()
