import AppKit

let smokeTest = CommandLine.arguments.contains("--self-test")
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let pasteboard = smokeTest ? NSPasteboard.withUniqueName() : .general
let delegate = ApplicationController(clipboard: Clipboard(pasteboard: pasteboard), smokeTest: smokeTest)
app.delegate = delegate
withExtendedLifetime(delegate) { app.run() }
