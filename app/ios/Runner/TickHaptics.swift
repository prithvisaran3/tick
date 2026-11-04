import AVFoundation
import CoreHaptics
import Flutter
import UIKit

/// Tick's haptic language, played through Core Haptics.
///
/// Dart sends `play(pattern, tier)`; patterns are the AHAP files compiled from
/// design/haptics.json (tools/compile_ahap.py) and bundled as Flutter assets.
/// Modes: full | subtle (x0.5 intensity, no continuous events) | off.
/// Low Power Mode forces subtle. Sounds use an ambient audio session so the
/// silent switch mutes them.
public final class TickHapticsPlugin: NSObject, FlutterPlugin {
  private var engine: CHHapticEngine?
  private var mode = "full"
  private var soundOn = true
  private var cache: [String: URL] = [:]
  private var players: [String: AVAudioPlayer] = [:]
  private let registrar: FlutterPluginRegistrar

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    super.init()
    try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "tick/haptics", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(TickHapticsPlugin(registrar: registrar), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "prepare":
      startEngine()
      result(nil)
    case "setMode":
      mode = (args["mode"] as? String) ?? "full"
      result(nil)
    case "setSound":
      soundOn = (args["on"] as? Bool) ?? true
      result(nil)
    case "play":
      play(asset: args["asset"] as? String ?? "")
      result(nil)
    case "playSound":
      playSound(asset: args["asset"] as? String ?? "")
      result(nil)
    case "supportsHaptics":
      result(CHHapticEngine.capabilitiesForHardware().supportsHaptics)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private var effectiveMode: String {
    ProcessInfo.processInfo.isLowPowerModeEnabled && mode == "full" ? "subtle" : mode
  }

  private func startEngine() {
    guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
    if engine == nil {
      engine = try? CHHapticEngine()
      engine?.isAutoShutdownEnabled = true
      engine?.resetHandler = { [weak self] in try? self?.engine?.start() }
      engine?.stoppedHandler = { _ in }
    }
    try? engine?.start()
  }

  private func assetPath(_ asset: String) -> String? {
    let key = registrar.lookupKey(forAsset: asset)
    return Bundle.main.path(forResource: key, ofType: nil)
  }

  /// Returns the AHAP file to play for the current mode, writing a softened copy for subtle.
  private func ahapURL(asset: String) -> URL? {
    let m = effectiveMode
    let cacheKey = "\(m)|\(asset)"
    if let u = cache[cacheKey] { return u }
    guard let path = assetPath(asset) else { return nil }
    if m == "full" {
      let u = URL(fileURLWithPath: path)
      cache[cacheKey] = u
      return u
    }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let pattern = root["Pattern"] as? [[String: Any]] else { return nil }
    var out: [[String: Any]] = []
    for item in pattern {
      guard var event = item["Event"] as? [String: Any] else { continue }  // drop parameter curves in subtle
      if (event["EventType"] as? String) == "HapticContinuous" { continue }  // no continuous events in subtle
      if var params = event["EventParameters"] as? [[String: Any]] {
        for i in params.indices where (params[i]["ParameterID"] as? String) == "HapticIntensity" {
          params[i]["ParameterValue"] = ((params[i]["ParameterValue"] as? Double) ?? 1.0) * 0.5
        }
        event["EventParameters"] = params
      }
      out.append(["Event": event])
    }
    if out.isEmpty {  // e.g. the hold ramp is continuous-only: keep a single light tick so the press still answers
      out = [["Event": ["Time": 0.0, "EventType": "HapticTransient", "EventParameters": [
        ["ParameterID": "HapticIntensity", "ParameterValue": 0.2], ["ParameterID": "HapticSharpness", "ParameterValue": 0.3]]]]]
    }
    root["Pattern"] = out
    guard let bytes = try? JSONSerialization.data(withJSONObject: root) else { return nil }
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("tick-\(m)-\(asset.hashValue).ahap")
    try? bytes.write(to: u)
    cache[cacheKey] = u
    return u
  }

  private func play(asset: String) {
    guard effectiveMode != "off", CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
    startEngine()
    guard let url = ahapURL(asset: asset) else { return }
    try? engine?.playPattern(from: url)
  }

  private func playSound(asset: String) {
    guard soundOn, let path = assetPath(asset) else { return }
    if players[asset] == nil { players[asset] = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) }
    players[asset]?.currentTime = 0
    players[asset]?.play()
  }
}
