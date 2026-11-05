import Flutter
import UIKit

/// Files handed to Tick by the system: "Open in Tick" (Wallet, Files, Mail), and the Shortcuts action "Import statement to Tick".
/// The file is copied into the app's temp folder (the source is only readable while its security scope is open) and Dart is told
/// the path. Anything that arrives before Dart is listening (a cold start) waits in `pending` until Dart asks for it.
final class TickImportInbox {
  static let shared = TickImportInbox()
  private var pending: [String] = []
  weak var channel: FlutterMethodChannel?

  func receive(_ url: URL) {
    guard url.isFileURL else { return }
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("imports", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let safeName = url.lastPathComponent.replacingOccurrences(of: "/", with: "_")
    let dest = dir.appendingPathComponent("\(UUID().uuidString)-\(safeName)")
    do {
      try FileManager.default.copyItem(at: url, to: dest)
      deliver(dest.path)
    } catch {
      // Unreadable file: ignore. Nothing to show for a file Tick can't even copy.
    }
  }

  func deliver(_ path: String) {
    pending.append(path)                                     // always queued; Dart de-duplicates when it also gets the live event
    channel?.invokeMethod("opened", arguments: path)
  }

  func takePending() -> [String] {
    let p = pending
    pending = []
    return p
  }
}

final class TickImportPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "tick/import", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(TickImportPlugin(), channel: channel)
    TickImportInbox.shared.channel = channel
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "takePending": result(TickImportInbox.shared.takePending())
    default: result(FlutterMethodNotImplemented)
    }
  }
}
