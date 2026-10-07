/// App configuration. Secrets are NEVER hardcoded — they are injected at
/// build/run time with --dart-define:
///
///   flutter run --dart-define=OPENAI_API_KEY=sk-your-key-here
///
/// See `.env.example` for the documented variables.
class AppConfig {
  AppConfig._();

  /// Vision API key. Empty means "use the built-in mock AI" (zero cost,
  /// works offline, perfect for demos and store screenshots).
  static const String openAiApiKey = String.fromEnvironment(
    'OPENAI_API_KEY',
    defaultValue: '',
  );

  /// Vision-capable chat model used by [OpenAiVisionService].
  static const String openAiModel = String.fromEnvironment(
    'OPENAI_MODEL',
    defaultValue: 'gpt-4o-mini',
  );

  static bool get hasOpenAiKey => openAiApiKey.isNotEmpty;
}
