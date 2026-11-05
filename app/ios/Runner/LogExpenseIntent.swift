import AppIntents
import Foundation

/// "Log expense" for Siri, Shortcuts and the Action Button.
/// Saves the entry to the app's UserDefaults and opens Tick, which shows quick add prefilled (see lib/services/pending_add.dart).
@available(iOS 16.0, *)
struct LogExpenseIntent: AppIntent {
  static var title: LocalizedStringResource = "Log expense"
  static var description = IntentDescription("Add a purchase to Tick.")
  static var openAppWhenRun: Bool = true

  @Parameter(title: "Amount") var amount: Double
  @Parameter(title: "Merchant") var merchant: String?
  @Parameter(title: "Category") var category: String?

  static var parameterSummary: some ParameterSummary {
    Summary("Log \(\.$amount) at \(\.$merchant)")
  }

  func perform() async throws -> some IntentResult {
    var entry: [String: Any] = ["amount": amount]
    if let merchant { entry["merchant"] = merchant }
    if let category { entry["category"] = category }
    if let data = try? JSONSerialization.data(withJSONObject: entry), let s = String(data: data, encoding: .utf8) {
      // Same store shared_preferences reads ("flutter." prefix). No App Group needed, so this works with a free Apple account.
      UserDefaults.standard.set(s, forKey: "flutter.pendingAdd")
    }
    return .result()
  }
}

@available(iOS 16.4, *)
struct TickShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(intent: LogExpenseIntent(), phrases: ["Log an expense in \(.applicationName)", "Add a purchase to \(.applicationName)"], shortTitle: "Log expense", systemImageName: "plus.circle")
  }
}
