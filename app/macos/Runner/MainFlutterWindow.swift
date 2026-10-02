import Cocoa
import FlutterMacOS
import ServiceManagement

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerLoginItemChannel(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }

  /// "Launch at login" through the macOS login items (SMAppService).
  private func registerLoginItemChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "darkdial/login_item", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      let service = SMAppService.mainApp
      switch call.method {
      case "isEnabled":
        result(service.status == .enabled)
      case "setEnabled":
        do {
          if call.arguments as? Bool == true {
            try service.register()
          } else {
            try service.unregister()
          }
          result(service.status == .enabled)
        } catch {
          result(FlutterError(code: "login_item", message: error.localizedDescription, details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
