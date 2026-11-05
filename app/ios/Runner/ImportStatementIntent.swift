import AppIntents
import Foundation

/// Shortcuts action "Import statement to Tick": give it a file (for example the Apple Card CSV from Wallet) and Tick opens on the import
/// preview. The file is copied to the app's temp folder and handed to Dart the same way "Open in Tick" does. No App Group needed.
@available(iOS 16.0, *)
struct ImportStatementIntent: AppIntent {
  static var title: LocalizedStringResource = "Import statement to Tick"
  static var description = IntentDescription("Open a bank or Apple Card statement (CSV or OFX) in Tick to import it.")
  static var openAppWhenRun: Bool = true

  @Parameter(title: "Statement file", supportedTypeIdentifiers: ["public.comma-separated-values-text", "public.plain-text", "public.data"])
  var file: IntentFile

  static var parameterSummary: some ParameterSummary {
    Summary("Import \(\.$file) to Tick")
  }

  func perform() async throws -> some IntentResult {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("imports", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let name = (file.filename.isEmpty ? "statement.csv" : file.filename).replacingOccurrences(of: "/", with: "_")
    let dest = dir.appendingPathComponent("\(UUID().uuidString)-\(name)")
    try file.data.write(to: dest)
    TickImportInbox.shared.deliver(dest.path)
    return .result()
  }
}
