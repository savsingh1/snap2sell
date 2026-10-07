import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/ai_analysis_result.dart';
import 'ai_logger.dart';
import 'ai_service.dart';
import 'pricing_service.dart';

/// Live backend: sends the photo to the Snap2Sell analysis backend
/// (Cloud Function), which calls Gemini server-side and returns structured
/// product identification.
///
/// Security properties:
/// - The Gemini API key NEVER leaves the server; the app only knows the
///   backend URL and a lightweight app secret (abuse friction, not a key).
/// - Errors surfaced to the UI are sanitized [AiServiceException]s with a
///   category + friendly message. Raw exceptions (which could contain URLs)
///   are mapped here and never propagated.
///
/// Reliability properties:
/// - 60s per-attempt timeout; one automatic retry for transport-level
///   failures (the server itself retries Gemini with exponential backoff).
/// - Retries only happen for network/timeout failures — never for 400/401.
/// - The in-flight request is never orphaned: [dispose] cancels the client.
class Snap2SellBackendService implements AiService {
  Snap2SellBackendService({
    required this.backendUrl,
    required this.appSecret,
    PricingService? pricing,
    http.Client? client,
  })  : _pricing = pricing ?? AiEstimatePricingService(),
        _client = client ?? http.Client();

  final String backendUrl;
  final String appSecret;
  final PricingService _pricing;
  final http.Client _client;
  bool _disposed = false;

  /// Confidence below this triggers the "take another photo" guidance
  /// instead of a weak listing.
  static const int lowConfidenceThreshold = 60;

  static const Duration _attemptTimeout = Duration(seconds: 60);

  @override
  Future<AiAnalysisResult> analyzeItem(Uint8List photoBytes) async {
    final startedAt = DateTime.now();
    AiServiceException? lastError;
    // One automatic retry for transport failures only (attempt 2).
    // The server already retries Gemini itself with backoff.
    for (var attempt = 1; attempt <= 2; attempt++) {
      final attemptStart = DateTime.now();
      try {
        final result = await _attemptOnce(photoBytes);
        final ms = DateTime.now().difference(startedAt).inMilliseconds;
        AiLogger.attempt(
          attempt: attempt,
          durationMs: DateTime.now().difference(attemptStart).inMilliseconds,
          statusCode: 200,
        );
        AiLogger.success(
          durationMs: ms,
          attempts: attempt,
          confidence: result.confidence,
          recognized: result.recognized,
        );
        return _toListing(result);
      } on _TransportFailure catch (e) {
        lastError = e.error;
        AiLogger.attempt(
          attempt: attempt,
          durationMs: DateTime.now().difference(attemptStart).inMilliseconds,
          statusCode: 0,
        );
        if (attempt == 2) break;
        await Future<void>.delayed(const Duration(seconds: 1));
      } on AiServiceException catch (e) {
        // Categorized failure (auth, bad image, rate limit, ...) — retrying
        // won't help. Surface it.
        final ms = DateTime.now().difference(startedAt).inMilliseconds;
        AiLogger.failure(
          category: e.category,
          durationMs: ms,
          attempts: attempt,
        );
        rethrow;
      }
    }
    final ms = DateTime.now().difference(startedAt).inMilliseconds;
    final err = lastError ??
        AiServiceException(
          'Network failure.',
          category: AiErrorCategory.network,
        );
    AiLogger.failure(category: err.category, durationMs: ms, attempts: 2);
    throw err;
  }

  /// Multi-photo analysis: sends up to 5 photos of the same item in one
  /// request via the backend's `images` array. Same retry/failure semantics
  /// as [analyzeItem]; the single-photo method is untouched.
  @override
  Future<AiAnalysisResult> analyzeItems(List<Uint8List> photos) async {
    assert(photos.isNotEmpty && photos.length <= 5);
    final startedAt = DateTime.now();
    AiServiceException? lastError;
    for (var attempt = 1; attempt <= 2; attempt++) {
      final attemptStart = DateTime.now();
      try {
        final result = await _attemptMultiOnce(photos);
        final ms = DateTime.now().difference(startedAt).inMilliseconds;
        AiLogger.attempt(
          attempt: attempt,
          durationMs: DateTime.now().difference(attemptStart).inMilliseconds,
          statusCode: 200,
        );
        AiLogger.success(
          durationMs: ms,
          attempts: attempt,
          confidence: result.confidence,
          recognized: result.recognized,
        );
        return _toListing(result);
      } on _TransportFailure catch (e) {
        lastError = e.error;
        AiLogger.attempt(
          attempt: attempt,
          durationMs: DateTime.now().difference(attemptStart).inMilliseconds,
          statusCode: 0,
        );
        if (attempt == 2) break;
        await Future<void>.delayed(const Duration(seconds: 1));
      } on AiServiceException catch (e) {
        final ms = DateTime.now().difference(startedAt).inMilliseconds;
        AiLogger.failure(
          category: e.category,
          durationMs: ms,
          attempts: attempt,
        );
        rethrow;
      }
    }
    final ms = DateTime.now().difference(startedAt).inMilliseconds;
    final err = lastError ??
        AiServiceException(
          'Network failure.',
          category: AiErrorCategory.network,
        );
    AiLogger.failure(category: err.category, durationMs: ms, attempts: 2);
    throw err;
  }

  Future<ProductIdentification> _attemptMultiOnce(
      List<Uint8List> photos) async {
    http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('$backendUrl/'),
            headers: {
              'Content-Type': 'application/json',
              if (appSecret.isNotEmpty) 'x-app-secret': appSecret,
            },
            body: jsonEncode({
              'images': [for (final p in photos) base64Encode(p)],
              'mimeType': 'image/jpeg',
            }),
          )
          .timeout(_attemptTimeout);
    } on TimeoutException {
      throw _TransportFailure(AiServiceException(
        'Analysis timed out.',
        category: AiErrorCategory.timeout,
      ));
    } on SocketException {
      throw _TransportFailure(AiServiceException(
        'Network failure.',
        category: AiErrorCategory.network,
      ));
    } on HttpException {
      throw _TransportFailure(AiServiceException(
        'Network failure.',
        category: AiErrorCategory.network,
      ));
    } on http.ClientException {
      throw _TransportFailure(AiServiceException(
        'Network failure.',
        category: AiErrorCategory.network,
      ));
    }

    return _parseResponse(response);
  }

  Future<ProductIdentification> _attemptOnce(Uint8List photoBytes) async {
    http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('$backendUrl/'),
            headers: {
              'Content-Type': 'application/json',
              if (appSecret.isNotEmpty) 'x-app-secret': appSecret,
            },
            body: jsonEncode({
              'imageBase64': base64Encode(photoBytes),
              'mimeType': 'image/jpeg',
            }),
          )
          .timeout(_attemptTimeout);
    } on TimeoutException {
      throw _TransportFailure(AiServiceException(
        'Analysis timed out.',
        category: AiErrorCategory.timeout,
      ));
    } on SocketException {
      throw _TransportFailure(AiServiceException(
        'Network failure.',
        category: AiErrorCategory.network,
      ));
    } on HttpException {
      throw _TransportFailure(AiServiceException(
        'Network failure.',
        category: AiErrorCategory.network,
      ));
    } on http.ClientException {
      // NOTE: ClientException.toString() embeds the request URI — we map it
      // to a sanitized category here and never propagate the raw text.
      throw _TransportFailure(AiServiceException(
        'Network failure.',
        category: AiErrorCategory.network,
      ));
    }

    return _parseResponse(response);
  }

  ProductIdentification _parseResponse(http.Response response) {
    if (response.statusCode == 200) {
      Map<String, dynamic> json;
      try {
        json = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {
        throw AiServiceException(
          'Bad response.',
          category: AiErrorCategory.invalidResponse,
        );
      }
      final id = ProductIdentification.fromJson(json);
      _throwIfLowConfidence(id);
      return id;
    }

    // Error envelope from the backend: { error: { category, message } }.
    // The server's message is already user-safe.
    AiErrorCategory category = AiErrorCategory.model;
    String? serverMessage;
    try {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final err = json['error'] as Map<String, dynamic>?;
      serverMessage = err?['message'] as String?;
      category = _categoryFromName(err?['category'] as String?);
    } catch (_) {
      // fall through to status-based mapping
    }

    switch (response.statusCode) {
      case 400:
      case 413:
        throw AiServiceException(
          serverMessage ?? 'Bad image.',
          category: AiErrorCategory.badImage,
        );
      case 401:
      case 403:
        throw AiServiceException(
          'Service unavailable.',
          category: AiErrorCategory.auth,
        );
      case 429:
        throw AiServiceException(
          serverMessage ?? 'Rate limited.',
          category: AiErrorCategory.rateLimit,
        );
      default:
        throw AiServiceException(
          serverMessage ?? 'Backend error ${response.statusCode}.',
          category: category,
        );
    }
  }

  AiErrorCategory _categoryFromName(String? name) {
    switch (name) {
      case 'NETWORK_ERROR':
        return AiErrorCategory.network;
      case 'TIMEOUT':
        return AiErrorCategory.timeout;
      case 'AUTH_ERROR':
        return AiErrorCategory.auth;
      case 'RATE_LIMIT':
        return AiErrorCategory.rateLimit;
      case 'BAD_IMAGE':
        return AiErrorCategory.badImage;
      case 'INVALID_RESPONSE':
        return AiErrorCategory.invalidResponse;
      case 'LOW_CONFIDENCE':
        return AiErrorCategory.lowConfidence;
      default:
        return AiErrorCategory.model;
    }
  }

  /// Phase 6 — low-confidence recovery: instead of a weak listing, tell the
  /// user exactly which photo to take next.
  void _throwIfLowConfidence(ProductIdentification id) {
    final weak = !id.recognized ||
        id.needsMorePhotos ||
        id.confidence < lowConfidenceThreshold;
    if (!weak) return;
    final tips = id.recommendedPhotos.where((s) => s.isNotEmpty).take(2).toList();
    final guidance = tips.isNotEmpty
        ? 'We need a clearer photo to identify this product. ${tips.join(' ')}'
        : 'We need a clearer photo to identify this product. Try a straight-on shot of the front, logo, or model-number label.';
    throw AiServiceException(
      guidance,
      category: AiErrorCategory.lowConfidence,
    );
  }

  AiAnalysisResult _toListing(ProductIdentification id) {
    final price = _pricing.estimatePrice(id);
    return AiAnalysisResult.fromIdentification(
      id,
      priceLow: price.low,
      priceHigh: price.high,
      suggestedPrice: price.suggested,
    );
  }

  void dispose() {
    _disposed = true;
    _client.close();
  }

  bool get isDisposed => _disposed;
}

/// Internal marker: the request never completed at the transport level and
/// may be retried. Never escapes this service.
class _TransportFailure implements Exception {
  _TransportFailure(this.error);
  final AiServiceException error;
}
