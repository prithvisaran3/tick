import AVFoundation
import CoreHaptics
import Flutter
import UIKit

/// Tick's haptic language, played through Core Haptics.
///
/// Dart sends `play(asset)`; assets are the AHAP files compiled from design/haptics.json (tools/compile_ahap.py) bundled as Flutter assets.
/// Modes: full | subtle (x0.5 intensity, no continuous events) | off. Low Power Mode forces subtle.
/// Sounds use an ambient audio session so the silent switch mutes them.
///
/// Threading: every Core Haptics and AVFoundation call runs on one private serial queue. Starting the haptic engine
/// or an audio session can block for a long time on the first call; doing that on the main thread froze the whole UI
/// (iOS logged "System gesture gate timed out"). Method calls therefore return to Dart immediately.
/// Everything fails soft: a missing file, an unsupported device or an engine error means "no haptic", never a crash.
public final class TickHapticsPlugin: NSObject, FlutterPlugin {
  private let queue = DispatchQueue(label: "app.tick.haptics", qos: .userInitiated)
  private var engine: CHHapticEngine?
  private var mode = "full"
  private var soundOn = true
  private var cache: [String: URL] = [:]
  private var players: [String: AVAudioPlayer] = [:]
  private var audioReady = false
  private let registrar: FlutterPluginRegistrar
  private let supportsHaptics: Bool

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    self.supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "tick/haptics", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(TickHapticsPlugin(registrar: registrar), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "prepare":
      queue.async { self.startEngine() }
      result(nil)
    case "setMode":
      let m = (args["mode"] as? String) ?? "full"
      queue.async { self.mode = m }
      result(nil)
    case "setSound":
      let on = (args["on"] as? Bool) ?? true
      queue.async { self.soundOn = on }
      result(nil)
    case "play":
      let asset = args["asset"] as? String ?? ""
      queue.async { self.play(asset: asset) }
      result(nil)
    case "playSound":
      let asset = args["asset"] as? String ?? ""
      queue.async { self.playSound(asset: asset) }
      result(nil)
    case "supportsHaptics":
      result(supportsHaptics)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - queue-only helpers

  private var effectiveMode: String {
    ProcessInfo.processInfo.isLowPowerModeEnabled && mode == "full" ? "subtle" : mode
  }

  private func startEngine() {
    guard supportsHaptics else { return }
    if engine == nil {
      do {
        let e = try CHHapticEngine()
        e.isAutoShutdownEnabled = true
        e.resetHandler = { [weak self] in self?.queue.async { try? self?.engine?.start() } }
        e.stoppedHandler = { [weak self] _ in self?.queue.async { self?.engine = nil } }   // re-created on the next play
        engine = e
      } catch {
        engine = nil
        return
      }
    }
    try? engine?.start()
  }

  /// Absolute path of a Flutter asset inside the app bundle, or nil if it is not there.
  private func assetPath(_ asset: String) -> String? {
    let key = registrar.lookupKey(forAsset: asset)
    guard let path = Bundle.main.path(forResource: key, ofType: nil), FileManager.default.fileExists(atPath: path) else { return nil }
    return path
  }

  /// The AHAP file to play for the current mode; writes a softened copy for subtle.
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
      guard var event = item["Event"] as? [String: Any] else { continue }            // drop parameter curves in subtle
      if (event["EventType"] as? String) == "HapticContinuous" { continue }          // no continuous events in subtle
      if var params = event["EventParameters"] as? [[String: Any]] {
        for i in params.indices where (params[i]["ParameterID"] as? String) == "HapticIntensity" {
          params[i]["ParameterValue"] = ((params[i]["ParameterValue"] as? Double) ?? 1.0) * 0.5
        }
        event["EventParameters"] = params
      }
      out.append(["Event": event])
    }
    if out.isEmpty {                                                                  // continuous-only patterns keep one light tick
      out = [["Event": ["Time": 0.0, "EventType": "HapticTransient", "EventParameters": [
        ["ParameterID": "HapticIntensity", "ParameterValue": 0.2], ["ParameterID": "HapticSharpness", "ParameterValue": 0.3]]]]]
    }
    root["Pattern"] = out
    guard let bytes = try? JSONSerialization.data(withJSONObject: root) else { return nil }
    let name = asset.replacingOccurrences(of: "/", with: "_")
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("tick-\(m)-\(name)")
    do { try bytes.write(to: u) } catch { return nil }
    cache[cacheKey] = u
    return u
  }

  private func play(asset: String) {
    guard effectiveMode != "off", supportsHaptics else { return }
    if engine == nil { startEngine() }
    guard let url = ahapURL(asset: asset) else { return }
    do { try engine?.playPattern(from: url) } catch {
      engine = nil                                                                    // engine died (backgrounded): rebuild on the next call
    }
  }

  private func playSound(asset: String) {
    guard soundOn else { return }
    if !audioReady {
      try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
      audioReady = true
    }
    if players[asset] == nil {
      guard let path = assetPath(asset) else { return }
      let p = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
      p?.prepareToPlay()
      players[asset] = p
    }
    players[asset]?.currentTime = 0
    players[asset]?.play()
  }
}
