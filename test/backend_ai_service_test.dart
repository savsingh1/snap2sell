import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:snap2sell/models/ai_analysis_result.dart';
import 'package:snap2sell/services/backend_ai_service.dart';

/// Builds a real JPEG in memory so tests exercise the real image pipeline.
Uint8List makeTestJpeg({int w = 800, int h = 600}) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(210, 190, 160));
  img.drawString(image, 'TEST', font: img.arial24,
      x: 40, y: 40, color: img.ColorRgb8(40, 40, 40));
  return Uint8List.fromList(img.encodeJpg(image, quality: 90));
}

/// Ninja-style appliance identification, as the backend would return it.
Map<String, dynamic> ninjaIdentification({int confidence = 85}) => {
      'recognized': true,
      'brand': 'Ninja',
      'product_name': 'Countertop Blender',
      'model': '',
      'product_family': 'blender',
      'category': 'Appliances',
      'subcategory': 'Blenders',
      'color': 'Black',
      'condition': 'good',
      'visible_damage': [],
      'included_accessories': ['pitcher', 'lid'],
      'missing_parts': [],
      'search_keywords': ['ninja', 'blender', 'countertop'],
      'suggested_title': 'Ninja Countertop Blender — Black',
      'short_description':
          'Ninja countertop blender in black with pitcher and lid. Powers on per seller; sold as-is, please confirm condition.',
      'price_low': 40,
      'price_high': 70,
      'suggested_price': 55,
      'confidence': confidence,
      'needs_more_photos': false,
      'recommended_photos': [],
    };

Snap2SellBackendService serviceWith(MockClient client,
        {String secret = 'test-secret'}) =>
    Snap2SellBackendService(
      backendUrl: 'https://backend.example.com',
      appSecret: secret,
      client: client,
    );

/// Builds a UTF-8 JSON response (http.Response defaults to Latin1 and chokes
/// on characters like the em-dash).
http.Response jsonResponse(Object json, int status) => http.Response.bytes(
      utf8.encode(jsonEncode(json)),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

void main() {
  group('Snap2SellBackendService', () {
    test('clear branded product photo returns a listing (Ninja blender)',
        () async {
      final photo = makeTestJpeg();
      final service = serviceWith(MockClient((request) async {
        // The app secret must ride along as abuse friction.
        expect(request.headers['x-app-secret'], 'test-secret');
        expect(request.headers['Content-Type'], contains('application/json'));
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['imageBase64'], isNotEmpty);
        return jsonResponse(ninjaIdentification(), 200);
      }));

      final result = await service.analyzeItem(photo);

      expect(result.title, 'Ninja Countertop Blender — Black');
      expect(result.category, 'Appliances');
      expect(result.suggestedPrice, 55);
      expect(result.priceLow, 40);
      expect(result.priceHigh, 70);
      // Prices are labeled as estimates, never appraisals.
      expect(result.description, contains('AI estimate'));
    });

    test('brand visible but no model number: family set, model not invented',
        () async {
      final id = ninjaIdentification()..['model'] = '';
      final service = serviceWith(
          MockClient((_) async => jsonResponse(id, 200)));

      final result = await service.analyzeItem(makeTestJpeg());

      expect(result.title, isNotEmpty);
      // No model number was invented — title has no fake model suffix.
      expect(result.title.contains(RegExp(r'[A-Z]{2,}-\d+')), isFalse);
    });

    test('low confidence asks for another photo instead of a weak listing',
        () async {
      final id = ninjaIdentification(confidence: 42)
        ..['needs_more_photos'] = true
        ..['recommended_photos'] = [
          'Take a photo of the model-number label.'
        ];
      final service = serviceWith(
          MockClient((_) async => jsonResponse(id, 200)));

      final err = await _captureError(() => service.analyzeItem(makeTestJpeg()));

      expect(err, isNotNull);
      expect(err!.category, AiErrorCategory.lowConfidence);
      // Friendly, actionable — never "Product not recognized."
      expect(err.friendlyMessage, contains('model-number label'));
      expect(err.friendlyMessage, isNot(contains('Exception')));
    });

    test('unrecognized product asks for a clearer photo', () async {
      final id = ninjaIdentification(confidence: 20)..['recognized'] = false;
      final service = serviceWith(
          MockClient((_) async => jsonResponse(id, 200)));

      final err = await _captureError(() => service.analyzeItem(makeTestJpeg()));

      expect(err, isNotNull);
      expect(err!.category, AiErrorCategory.lowConfidence);
      expect(err.friendlyMessage, contains('clearer photo'));
    });

    test('network interruption: retries once, then friendly network error',
        () async {
      var calls = 0;
      final service = serviceWith(MockClient((_) async {
        calls++;
        throw const SocketException('Software caused connection abort');
      }));

      final err = await _captureError(() => service.analyzeItem(makeTestJpeg()));

      expect(calls, 2); // initial attempt + one retry
      expect(err, isNotNull);
      expect(err!.category, AiErrorCategory.network);
      expect(err.friendlyMessage, contains('connection'));
    });

    test('transient failure then success: retry recovers', () async {
      var calls = 0;
      final service = serviceWith(MockClient((_) async {
        calls++;
        if (calls == 1) throw const SocketException('connection reset');
        return jsonResponse(ninjaIdentification(), 200);
      }));

      final result = await service.analyzeItem(makeTestJpeg());

      expect(calls, 2);
      expect(result.title, contains('Ninja'));
    });

    test('THE KEY LEAK REGRESSION: ClientException never exposes URI or key',
        () async {
      const fakeKey = 'AIzaSy-FAKE-KEY-VALUE-12345';
      final service = serviceWith(MockClient((_) async {
        // Exactly what used to leak: ClientException embeds the request URI,
        // and the old code built the URI with ?key=<real key>.
        throw http.ClientException(
          'Software caused connection abort',
          Uri.parse(
              'https://generativelanguage.googleapis.com/v1beta/models/x:generateContent?key=$fakeKey'),
        );
      }));

      final err = await _captureError(() => service.analyzeItem(makeTestJpeg()));

      expect(err, isNotNull);
      expect(err!.category, AiErrorCategory.network);
      final shown = err.friendlyMessage;
      expect(shown, isNot(contains(fakeKey)));
      expect(shown, isNot(contains('generativelanguage')));
      expect(shown, isNot(contains('ClientException')));
      expect(shown, isNot(contains('http')));
      // And the raw exception text is gone too.
      expect(err.toString(), isNot(contains(fakeKey)));
    });

    test('timeout maps to the timeout category', () async {
      final service = serviceWith(MockClient((_) async {
        throw TimeoutException('too slow');
      }));

      final err = await _captureError(() => service.analyzeItem(makeTestJpeg()));

      expect(err, isNotNull);
      expect(err!.category, AiErrorCategory.timeout);
      expect(err.friendlyMessage, contains('too long'));
    });

    test('invalid credentials (401): auth error, no retry', () async {
      var calls = 0;
      final service = serviceWith(MockClient((_) async {
        calls++;
        return jsonResponse(
            {'error': {'category': 'AUTH_ERROR', 'message': 'x'}}, 401);
      }));

      final err = await _captureError(() => service.analyzeItem(makeTestJpeg()));

      expect(calls, 1); // permanent — never retried
      expect(err, isNotNull);
      expect(err!.category, AiErrorCategory.auth);
    });

    test('rate limit (429) surfaces the rate-limit message', () async {
      final service = serviceWith(MockClient((_) async => jsonResponse(
          {'error': {'category': 'RATE_LIMIT', 'message': 'Slow down.'}},
          429)));

      final err = await _captureError(() => service.analyzeItem(makeTestJpeg()));

      expect(err, isNotNull);
      expect(err!.category, AiErrorCategory.rateLimit);
    });

    test('temporary backend failure (503): honest model error', () async {
      final service = serviceWith(MockClient((_) async => jsonResponse(
          {
            'error': {
              'category': 'MODEL_ERROR',
              'message': "We couldn't analyze this photo right now."
            }
          },
          503)));

      final err = await _captureError(() => service.analyzeItem(makeTestJpeg()));

      expect(err, isNotNull);
      expect(err!.category, AiErrorCategory.model);
      expect(err.friendlyMessage, isNot(contains('503')));
    });

    test('unreadable photo (400): bad-image guidance', () async {
      final service = serviceWith(MockClient((_) async => jsonResponse(
          {'error': {'category': 'BAD_IMAGE', 'message': 'Not a photo.'}},
          400)));

      final err = await _captureError(() => service.analyzeItem(makeTestJpeg()));

      expect(err, isNotNull);
      expect(err!.category, AiErrorCategory.badImage);
    });

    test('malformed 200 body: invalid-response, never a crash', () async {
      final service = serviceWith(
          MockClient((_) async => http.Response('not json at all', 200)));

      final err = await _captureError(() => service.analyzeItem(makeTestJpeg()));

      expect(err, isNotNull);
      expect(err!.category, AiErrorCategory.invalidResponse);
    });

    test('multiple consecutive scans all succeed', () async {
      var calls = 0;
      final service = serviceWith(MockClient((_) async {
        calls++;
        return jsonResponse(ninjaIdentification(), 200);
      }));
      final photo = makeTestJpeg();

      for (var i = 0; i < 5; i++) {
        final result = await service.analyzeItem(photo);
        expect(result.title, contains('Ninja'));
      }
      expect(calls, 5);
    });

    test('friendly messages never contain technical details', () async {
      for (final category in AiErrorCategory.values) {
        final msg = AiServiceException('detail', category: category)
            .friendlyMessage
            .toLowerCase();
        expect(msg, isNot(contains('exception')));
        expect(msg, isNot(contains('http')));
        expect(msg, isNot(contains('stack')));
        expect(msg, isNot(contains('uri')));
      }
    });
  });
}

Future<AiServiceException?> _captureError(
    Future<AiAnalysisResult> Function() fn) async {
  try {
    await fn();
    return null;
  } on AiServiceException catch (e) {
    return e;
  }
}
