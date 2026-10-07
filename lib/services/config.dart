/// App configuration. Secrets are NEVER hardcoded and the Gemini API key
/// NEVER ships in this app — photo analysis goes through the Snap2Sell
/// backend (Cloud Function), which holds the key in Secret Manager.
///
/// Build/run time injection:
///   flutter run --dart-define=AI_BACKEND_URL=https://... \
///               --dart-define=APP_API_SECRET=...
///
/// Without AI_BACKEND_URL the app uses the built-in mock AI (zero cost,
/// works offline — good for demos and screenshots).
class AppConfig {
  AppConfig._();

  /// Base URL of the Snap2Sell analysis backend, e.g.
  /// https://analyzeproduct-xyz-uc.a.run.app (no trailing slash).
  /// Empty means "use the built-in mock AI".
  static const String aiBackendUrl = String.fromEnvironment(
    'AI_BACKEND_URL',
    defaultValue: '',
  );

  /// Shared secret sent as the x-app-secret header so the backend can tell
  /// our app apart from random internet traffic. This is abuse friction,
  /// not the Gemini key — the Gemini key never leaves the server.
  static const String appApiSecret = String.fromEnvironment(
    'APP_API_SECRET',
    defaultValue: '',
  );

  static bool get hasAiBackend => aiBackendUrl.isNotEmpty;
}
