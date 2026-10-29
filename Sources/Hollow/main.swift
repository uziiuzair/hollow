import AppKit
import DiskEngine

// Before any scan: touching a cloud folder or file must never download it.
forbidDatalessMaterialization()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
