import 'package:flutter/foundation.dart';

import '../models/ai_analysis_result.dart';

/// Internal diagnostics for the photo-analysis pipeline.
///
/// Logs request lifecycle events (start, image size, duration, retries,
/// error category, confidence) via [debugPrint] so they appear in dev
/// consoles but never in the UI.
///
/// SECURITY: never pass secrets, API keys, auth tokens, or full request
/// URLs here. [redact] defensively strips anything that looks like a
/// credential from free-form detail strings.
class AiLogger {
  AiLogger._();

  static final RegExp _secretPattern = RegExp(
    r'(key=|api[_-]?key["\s:=]+|bearer\s+)[A-Za-z0-9_\-]{8,}',
    caseSensitive: false,
  );

  /// Defensive scrub: masks anything resembling an embedded credential.
  static String redact(String input) =>
      input.replaceAllMapped(_secretPattern, (m) => '${m.group(1)}***');

  static void _log(String event, Map<String, Object?> fields) {
    final safe = fields.map((k, v) {
      final val = v?.toString() ?? '';
      return MapEntry(k, redact(val));
    });
    debugPrint('[Snap2Sell:AI] $event ${safe.entries.map((e) => '${e.key}=${e.value}').join(' ')}');
  }

  static void requestStarted({
    required int inBytes,
    required String mimeType,
    int? width,
    int? height,
  }) =>
      _log('request_started', {
        'inBytes': inBytes,
        'mimeType': mimeType,
        if (width != null) 'w': width,
        if (height != null) 'h': height,
      });

  static void imageCompressed({
    required int inBytes,
    required int outBytes,
    required int width,
    required int height,
  }) =>
      _log('image_compressed', {
        'inBytes': inBytes,
        'outBytes': outBytes,
        'w': width,
        'h': height,
      });

  static void attempt({
    required int attempt,
    required int durationMs,
    required int statusCode,
  }) =>
      _log('backend_attempt', {
        'attempt': attempt,
        'durationMs': durationMs,
        'status': statusCode,
      });

  static void success({
    required int durationMs,
    required int attempts,
    required int confidence,
    required bool recognized,
    String? model,
  }) =>
      _log('analysis_ok', {
        'durationMs': durationMs,
        'attempts': attempts,
        'confidence': confidence,
        'recognized': recognized,
        if (model != null) 'model': model,
      });

  static void failure({
    required AiErrorCategory category,
    required int durationMs,
    required int attempts,
    String? detail,
  }) =>
      _log('analysis_error', {
        'category': category.name,
        'durationMs': durationMs,
        'attempts': attempts,
        if (detail != null) 'detail': detail,
      });
}
