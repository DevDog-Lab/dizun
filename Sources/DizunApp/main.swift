import AppKit

// DIZUN app shell. One-shot utility: extract what was opened (double-click,
// Open With, Dock drop), run Finder Services, and leave. A plain launch
// shows the droplet window. Regular activation policy so the Dock icon is a
// drag-and-drop target; the bundle is assembled by scripts/build-app.sh.

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
