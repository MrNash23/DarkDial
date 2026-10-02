import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // Darkdial lives in the menu bar; closing the configuration window must not quit it.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
