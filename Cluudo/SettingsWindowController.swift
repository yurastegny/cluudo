import AppKit
import SwiftUI

@MainActor
class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(manager: WeatherManager) {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 604),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Cluudo Settings"
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.contentView = NSHostingView(rootView: SettingsView().environmentObject(manager))
        win.center()

        NSApp.setActivationPolicy(.regular)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
