import AuthenticationServices
import Flutter
import UIKit

/// Web sign-in (Supabase Google OAuth, Plaid Hosted Link) in an ASWebAuthenticationSession.
///
/// Why this exists: the flutter_web_auth_2 plugin finds its presentation window through `UIApplicationDelegate.window`, which is nil in an
/// app that uses the UIScene lifecycle (Tick does), and then falls back to the deprecated `UIApplication.keyWindow`. This channel
/// asks the connected UIWindowScene for its key window instead, so it works with scenes on current iOS. Dart falls back to the plugin if
/// this channel is unavailable.
final class TickWebAuthPlugin: NSObject, FlutterPlugin, ASWebAuthenticationPresentationContextProviding {
  private var session: ASWebAuthenticationSession?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "tick/webauth", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(TickWebAuthPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "authenticate",
          let args = call.arguments as? [String: Any],
          let urlString = args["url"] as? String,
          let url = URL(string: urlString),
          let scheme = args["scheme"] as? String else {
      result(FlutterMethodNotImplemented)
      return
    }
    let started = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { [weak self] callbackURL, error in
      self?.session = nil
      if let callbackURL = callbackURL {
        result(callbackURL.absoluteString)
        return
      }
      if let authError = error as? ASWebAuthenticationSessionError, authError.code == .canceledLogin {
        result(FlutterError(code: "CANCELED", message: "User canceled login", details: nil))
        return
      }
      result(FlutterError(code: "EUNKNOWN", message: error?.localizedDescription ?? "Unknown error", details: nil))
    }
    started.presentationContextProvider = self
    started.prefersEphemeralWebBrowserSession = false
    session = started                      // keep it alive while the sheet is up
    if !started.start() {
      session = nil
      result(FlutterError(code: "START_FAILED", message: "Could not start the sign-in sheet", details: nil))
    }
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    return windows.first(where: { $0.isKeyWindow }) ?? windows.first ?? ASPresentationAnchor()
  }
}
