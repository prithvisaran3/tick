/// Provided via --dart-define at build time (see docs/RUN_ON_MAC.md). No secrets: only public client config.
abstract final class Env {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabasePublishableKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
  static const apiBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: 'https://tick-api-production.up.railway.app');
  /// --dart-define=TICK_PERF=true shows Flutter's performance overlay (profile/debug builds).
  static const perfOverlay = bool.fromEnvironment('TICK_PERF');
  /// WidgetKit needs the App Groups capability (paid Apple Developer account). Off by default; --dart-define=TICK_WIDGETS=true turns the snapshot on.
  static const widgetsEnabled = bool.fromEnvironment('TICK_WIDGETS');
  static bool get hasSupabase => supabaseUrl.isNotEmpty && supabasePublishableKey.isNotEmpty;
}
