import AppKit

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate

// Hide dock icon (LSUIElement behavior)
NSApp.setActivationPolicy(.accessory)

app.run()
