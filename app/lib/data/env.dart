/// Provided via --dart-define at build time (see docs/RUN_ON_MAC.md). No secrets: only public client config.
abstract final class Env {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabasePublishableKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
  static const googleIosClientId = String.fromEnvironment('GOOGLE_OAUTH_IOS_CLIENT_ID');
  static const googleWebClientId = String.fromEnvironment('GOOGLE_OAUTH_WEB_CLIENT_ID');
  static const apiBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: 'https://tick-api-production.up.railway.app');
  static bool get hasSupabase => supabaseUrl.isNotEmpty && supabasePublishableKey.isNotEmpty;
}
