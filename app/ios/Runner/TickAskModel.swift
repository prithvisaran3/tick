import Flutter
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Ask Tick's on-device step: Apple's Foundation Models fills in which tool answers a question. It never sees the ledger and never produces a number.
/// Needs iOS 26 with Apple Intelligence on; anywhere else `available` says no and the server moves on.
final class TickAskModelPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "tick/ask_model", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(TickAskModelPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "available":
      result(TickAskModelPlugin.available())
    case "route":
      let args = call.arguments as? [String: Any]
      let question = args?["question"] as? String ?? ""
      #if canImport(FoundationModels)
      if #available(iOS 26.0, *) {
        Task { result(await TickToolRouter.route(question)) }
        return
      }
      #endif
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  static func available() -> Bool {
    #if canImport(FoundationModels)
    if #available(iOS 26.0, *) {
      if case .available = SystemLanguageModel.default.availability { return true }
    }
    #endif
    return false
  }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct TickToolCall {
  @Guide(description: "The one tool that answers the question", .anyOf(["spend_summary", "category_breakdown", "top_merchants", "compare_periods", "balance_now", "upcoming_bills", "subscriptions", "safe_to_spend", "payday_info", "tally_balances", "find_transactions", "what_if", "biggest", "none"]))
  var tool: String
  @Guide(description: "in when the question is about money coming in, otherwise out", .anyOf(["in", "out"]))
  var kind: String
}

@available(iOS 26.0, *)
enum TickToolRouter {
  static func route(_ question: String) async -> [String: Any]? {
    let session = LanguageModelSession(instructions: "You route personal finance questions to one tool. Never calculate anything. Reply none if no tool fits.")
    guard let r = try? await session.respond(to: question, generating: TickToolCall.self) else { return nil }
    let call = r.content
    if call.tool == "none" { return nil }
    return ["tool": call.tool, "params": call.kind == "in" ? ["kind": "in"] : [:]]
  }
}
#endif
