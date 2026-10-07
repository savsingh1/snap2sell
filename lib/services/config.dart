/// App configuration. Secrets are NEVER hardcoded — they are injected at
/// build/run time with --dart-define:
///
///   flutter run --dart-define=GEMINI_API_KEY=your-key-here
///
/// Free keys (no credit card) from https://aistudio.google.com.
/// See `.env.example` for the documented variables.
class AppConfig {
  AppConfig._();

  /// Vision API key. Empty means "use the built-in mock AI" (zero cost,
  /// works offline, perfect for demos and store screenshots).
  static const String geminiApiKey = String.fromEnvironment(
    'GEMINI_API_KEY',
    defaultValue: '',
  );

  /// Vision-capable Gemini model used by [GeminiVisionService].
  /// Flash models have a generous free tier.
  static const String geminiModel = String.fromEnvironment(
    'GEMINI_MODEL',
    defaultValue: 'gemini-2.5-flash',
  );

  static bool get hasGeminiKey => geminiApiKey.isNotEmpty;
}
