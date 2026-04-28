import Cocoa
import FlutterMacOS
import window_manager_plus


@main
class AppDelegate: FlutterAppDelegate {
    override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return !NSApp.windows.contains(where: { $0 is MainFlutterWindow })
    }

    override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}

