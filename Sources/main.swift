// WindowStrip: a bar in the strip to the left of the MacBook notch.
//
// One icon per window on the Space you are looking at (each notched display
// shows its own), grouped by app. The front window is highlighted. Hovering
// shows "App · window title" below the strip; clicking brings that exact
// window to the front. The bar stays under other apps' notch windows (such as
// Vorssaint's Dynamic Island). Right of the notch it covers app menus that
// run past the notch, and leaves the status items alone.
//
// Build and install: ./build.sh --install   Log: ~/Library/Logs/WindowStrip/WindowStrip.log
// What the bar shows right now: ~/Library/Caches/dev.windowstrip/state.json

import AppKit

Log.start()

// Writing to the window-list helper after it died must not end this process.
signal(SIGPIPE, SIG_IGN)

// launchd stops us with SIGTERM; write the log out first.
signal(SIGTERM, SIG_IGN)
let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminationSource.setEventHandler {
    Log.info("stop", "stopping (SIGTERM)")
    Log.flush()
    exit(0)
}
terminationSource.resume()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
controller.start()
app.run()
