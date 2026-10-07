import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:snap2sell/models/ai_analysis_result.dart';
import 'package:snap2sell/services/ai_service.dart';

/// Fake HTTP client that answers per requested model name.
class _ModelRoutingClient extends http.BaseClient {
  _ModelRoutingClient(this.handler);
  final http.Response Function(Uri uri) handler;
  final List<String> requestedModels = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final uri = request.url;
    final match = RegExp(r'models/([^:]+):generateContent').firstMatch(uri.path);
    requestedModels.add(match?.group(1) ?? '?');
    final response = handler(uri);
    return http.StreamedResponse(
      Stream.value(utf8.encode(response.body)),
      response.statusCode,
      headers: {'content-type': 'application/json'},
    );
  }
}

String _listingJson(String title) => jsonEncode({
      'candidates': [
        {
          'content': {
            'parts': [
              {
                'text': jsonEncode({
                  'title': title,
                  'category': 'Fashion',
                  'condition': 'good',
                  'priceLow': 20,
                  'priceHigh': 40,
                  'suggestedPrice': 30,
                  'description': 'A test wallet, priced as an estimate.',
                }),
              },
            ],
          },
        },
      ],
    });

void main() {
  group('GeminiVisionService model fallback', () {
    test('falls through a retired (404) model to the next one', () async {
      final client = _ModelRoutingClient((uri) {
        if (uri.path.contains('gemini-3.6-flash')) {
          return http.Response(
              '{"error":{"code":404,"message":"not available"}}', 404);
        }
        return http.Response(_listingJson('Wallet via fallback'), 200);
      });
      final service = GeminiVisionService(apiKey: 'test-key', client: client);

      final result =
          await service.analyzeItem(Uint8List.fromList([1, 2, 3]));

      expect(result.title, 'Wallet via fallback');
      expect(client.requestedModels,
          ['gemini-3.6-flash', 'gemini-3.5-flash']);
    });

    test('falls through an overloaded (503) model to the next one', () async {
      final client = _ModelRoutingClient((uri) {
        if (uri.path.contains('gemini-3.6-flash')) {
          return http.Response('{"error":{"code":503}}', 503);
        }
        return http.Response(_listingJson('Wallet via 503 fallback'), 200);
      });
      final service = GeminiVisionService(apiKey: 'test-key', client: client);

      final result =
          await service.analyzeItem(Uint8List.fromList([1, 2, 3]));

      expect(result.title, 'Wallet via 503 fallback');
      expect(client.requestedModels,
          ['gemini-3.6-flash', 'gemini-3.5-flash']);
    });

    test('throws (no fake data) when every model is retired', () async {
      final client = _ModelRoutingClient(
          (_) => http.Response('{"error":{"code":404}}', 404));
      final service = GeminiVisionService(apiKey: 'test-key', client: client);

      expect(
        () => service.analyzeItem(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<AiServiceException>()),
      );
    });

    test('does not try fallbacks on auth failure (401)', () async {
      final client = _ModelRoutingClient(
          (_) => http.Response('{"error":{"code":401}}', 401));
      final service = GeminiVisionService(apiKey: 'bad-key', client: client);

      await expectLater(
        service.analyzeItem(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<AiServiceException>()),
      );
      // Only the preferred model was attempted — no masking of real errors.
      expect(client.requestedModels, ['gemini-3.6-flash']);
    });
  });
}
