import Cocoa

// Explicit entry point so the lifecycle does not depend on a storyboard.
// Make sure no other file declares @main / @NSApplicationMain.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// .accessory = menu bar app only, no Dock icon, no app menu.
// (LSUIElement in Info.plist does the same; we set both for safety.)
app.setActivationPolicy(.accessory)
app.run()
