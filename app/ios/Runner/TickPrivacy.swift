import Flutter
import UIKit

/// Privacy helpers the Dart side can't do itself.
/// - protect(paths): the offline cache files get NSFileProtectionComplete (unreadable while the phone is locked) and are excluded
///   from iCloud and device backups.
/// - isCaptured / "captured" events: the screen is being recorded, mirrored or AirPlayed; Dart covers amounts while that's true.
///   (iOS gives apps no way to block a screenshot, so screenshots are not covered: see docs/SECURITY.md.)
final class TickPrivacyPlugin: NSObject, FlutterPlugin {
  private var channel: FlutterMethodChannel?
  private var observer: NSObjectProtocol?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "tick/privacy", binaryMessenger: registrar.messenger())
    let instance = TickPrivacyPlugin()
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
    instance.observer = NotificationCenter.default.addObserver(forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main) { [weak instance] _ in
      instance?.channel?.invokeMethod("captured", arguments: TickPrivacyPlugin.captured())
    }
  }

  deinit {
    if let o = observer { NotificationCenter.default.removeObserver(o) }
  }

  private static func captured() -> Bool {
    for scene in UIApplication.shared.connectedScenes {
      if let ws = scene as? UIWindowScene, ws.screen.isCaptured { return true }
    }
    return false
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isCaptured":
      result(TickPrivacyPlugin.captured())
    case "protect":
      guard let args = call.arguments as? [String: Any], let paths = args["paths"] as? [String] else {
        result(FlutterError(code: "bad_args", message: nil, details: nil)); return
      }
      var done = 0
      for p in paths where FileManager.default.fileExists(atPath: p) {
        do {
          try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: p)
          var url = URL(fileURLWithPath: p)
          var values = URLResourceValues()
          values.isExcludedFromBackup = true
          try url.setResourceValues(values)
          done += 1
        } catch {
          // Soft-fail: the cache is an optimisation, never a reason to crash.
        }
      }
      result(done)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
