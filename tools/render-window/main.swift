import Cocoa

// Draws the main window offscreen, against whatever is really attached to the
// machine this runs on.
//
// A screenshot needs the window to be on the visible Space and the machine free for
// a moment. This needs neither, so it can be run over ssh on a Mac somebody else is
// sitting at - which is exactly the case the README screenshots kept failing on.
//
// It drives a real Monitor rather than fixtures: the rows, rates, bars and sessions
// are the machine's own. tools/render-card renders one hover card from a fixture and
// answers "does this layout hold"; this answers "what does the app actually look
// like with four cards in it".
//
// Run it through tools/render-window.sh, which compiles it against Sources/ and can
// put real read traffic on the cards first so the charts have something to show.

_ = NSApplication.shared

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/window"
func env(_ name: String, _ fallback: Double) -> Double {
    ProcessInfo.processInfo.environment[name].flatMap(Double.init) ?? fallback
}
let sample = env("SAMPLE", 10)
let width = CGFloat(env("WIDTH", 1100))
let height = CGFloat(env("HEIGHT", 820))

try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
// The app seeds this at launch; without it the catalogue is empty and every
// judgement the window makes would be missing.
Catalogue.seedIfMissing()

/// One pass: sample for a while with the traffic running, then draw.
///
/// Both halves have to be told which appearance this is. Palette has no running
/// application to ask, and AppKit's dynamic colours resolve against the *view's*
/// effectiveAppearance - which, for a view with no window, comes from NSApp and so
/// from whatever this Mac happens to be set to. Miss the second and the two passes
/// render identically, which looks like a working check and is not one.
func render(light: Bool, to path: String) {
    Palette.forcedAppearance = light
    let root = RootView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    root.appearance = NSAppearance(named: light ? .aqua : .darkAqua)

    let monitor = Monitor()
    monitor.interval = 1

    func refresh() {
        let unit: RateUnit = .bytes
        root.usbList.unit = unit
        root.netList.unit = unit
        root.usbList.update(monitor.usbRows)
        root.usbList.emptyMessage = "No storage devices"
        root.netList.update(monitor.networkRows)
        root.netList.emptyMessage = "No active interfaces"
        root.historyList.attached = monitor.usbRows
        root.historyList.unit = unit
        // Running sessions first, the same order the window itself uses.
        root.historyList.sessions = TransferLog.shared.inFlight + TransferLog.shared.sessions
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
    }
    monitor.onUpdate = refresh
    monitor.start()
    refresh()

    // Pump the run loop rather than sleeping: the monitor samples on a timer, and a
    // sleeping thread would never let it fire, leaving every rate at zero.
    let deadline = Date().addingTimeInterval(sample)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
    }
    refresh()

    guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
    root.cacheDisplay(in: root.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
    print("  \(path)  \(Int(width))x\(Int(height))  "
        + "\(monitor.usbRows.count) storage, \(monitor.networkRows.count) network")
}

render(light: false, to: out + "/window-dark.png")
render(light: true, to: out + "/window-light.png")
