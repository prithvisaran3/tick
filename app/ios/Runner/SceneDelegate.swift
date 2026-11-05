import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  // "Open in Tick": a statement file shared from Wallet or Files arrives as a file URL, on launch or while running.
  override func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    for context in connectionOptions.urlContexts where context.url.isFileURL {
      TickImportInbox.shared.receive(context.url)
    }
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    super.scene(scene, openURLContexts: URLContexts)
    for context in URLContexts where context.url.isFileURL {
      TickImportInbox.shared.receive(context.url)
    }
  }
}
