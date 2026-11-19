import AppKit

// DIZUN app shell. One-shot utility: extract what was opened, run Finder
// Services, and leave. A small droplet window appears on a plain launch.
// The bundle is assembled by scripts/build-app.sh (LSUIElement, ad-hoc sign).

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
