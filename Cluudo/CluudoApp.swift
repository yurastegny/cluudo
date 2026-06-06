import AppKit

@main
struct CluudoApp {
    static func main() {
        let app = NSApplication.shared

        if isAnotherInstanceRunning() {
            app.terminate(nil)
            return
        }

        app.setActivationPolicy(.accessory)
        let controller = StatusBarController()
        app.delegate = controller
        app.run()
    }

    private static func isAnotherInstanceRunning() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }
        let currentPID = ProcessInfo.processInfo.processIdentifier

        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { $0.processIdentifier != currentPID }
    }
}
