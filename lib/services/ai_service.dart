import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/ai_analysis_result.dart';
import 'config.dart';

/// Contract every AI backend must satisfy: photo bytes in, listing data out.
///
/// Bytes (not [File]) keep this working on every platform, including web
/// where dart:io files do not exist.
abstract class AiService {
  /// Analyzes [photoBytes] and returns a structured listing draft.
  /// Throws [AiServiceException] when the backend cannot complete the task.
  Future<AiAnalysisResult> analyzeItem(Uint8List photoBytes);
}

/// Picks the right backend: live vision API when a key is configured,
/// otherwise the offline mock (the default — zero keys, zero cost).
abstract final class AiServiceFactory {
  static AiService create() {
    if (AppConfig.hasGeminiKey) {
      return GeminiVisionService(
        apiKey: AppConfig.geminiApiKey,
        model: AppConfig.geminiModel,
      );
    }
    return MockAiService();
  }
}

/// Offline demo backend. Returns realistic, varied listing data for common
/// household items so the whole app flow can be demoed with no API key.
/// The [seed] can force a specific sample (handy for screenshots/tests).
class MockAiService implements AiService {
  MockAiService({int? seed}) : _random = Random(seed);

  final Random _random;

  static const List<Map<String, dynamic>> _samples = [
    {
      'title': 'IKEA LACK Side Table — White',
      'category': 'Furniture',
      'condition': 'good',
      'priceLow': 8,
      'priceHigh': 18,
      'suggestedPrice': 12,
      'description':
          'IKEA LACK side table in white. Sturdy and lightweight — perfect as a nightstand, plant stand, or end table. Light surface wear consistent with normal use, no wobbles or damage. From a smoke-free home. Pickup only, cash or e-transfer.',
    },
    {
      'title': 'KitchenAid Artisan Stand Mixer — Empire Red',
      'category': 'Appliances',
      'condition': 'excellent',
      'priceLow': 220,
      'priceHigh': 320,
      'suggestedPrice': 275,
      'description':
          'KitchenAid Artisan 5-qt stand mixer in Empire Red. Works perfectly — used a handful of times for baking. Includes flat beater, dough hook, and wire whip. No chips, scratches, or mechanical issues. Retails over \$600 new. A workhorse for any kitchen.',
    },
    {
      'title': 'Apple iPhone 12 — 128GB, Unlocked',
      'category': 'Electronics',
      'condition': 'good',
      'priceLow': 180,
      'priceHigh': 260,
      'suggestedPrice': 220,
      'description':
          'iPhone 12, 128GB, factory unlocked for any carrier. Battery health 87%. Screen and body in good shape with light micro-scratches (always kept in a case). Fully reset and iCloud removed — ready to activate. No box, includes a charging cable.',
    },
    {
      'title': 'Nike Air Zoom Pegasus — Men\'s Size 10',
      'category': 'Fashion',
      'condition': 'likeNew',
      'priceLow': 45,
      'priceHigh': 75,
      'suggestedPrice': 60,
      'description':
          'Nike Air Zoom Pegasus running shoes, men\'s US 10. Worn twice indoors — essentially new, no wear on the soles. Super comfortable daily trainers. Selling because the fit runs narrow for me. No box.',
    },
    {
      'title': 'LEGO Star Wars Millennium Falcon (75192-size set)',
      'category': 'Toys & Games',
      'condition': 'fair',
      'priceLow': 25,
      'priceHigh': 45,
      'suggestedPrice': 35,
      'description':
          'LEGO Star Wars spaceship set, mostly complete (a few small pieces may be missing — priced accordingly). Great for a collector or a kid who just wants to build and play. Manual included. From a smoke-free, pet-friendly home.',
    },
    {
      'title': 'Dyson V8 Cordless Vacuum',
      'category': 'Appliances',
      'condition': 'good',
      'priceLow': 140,
      'priceHigh': 210,
      'suggestedPrice': 175,
      'description':
          'Dyson V8 cordless stick vacuum. Strong suction, holds a charge for about 30 minutes. Includes wall mount, charger, and 3 attachments. Bin and filter freshly cleaned. Ideal for apartments or quick cleanups.',
    },
  ];

  @override
  Future<AiAnalysisResult> analyzeItem(Uint8List photoBytes) async {
    // Simulate the multi-step pipeline so the Processing screen feels real.
    await Future<void>.delayed(const Duration(milliseconds: 900));
    await Future<void>.delayed(const Duration(milliseconds: 900));
    await Future<void>.delayed(const Duration(milliseconds: 900));

    final sample = _samples[_random.nextInt(_samples.length)];
    return AiAnalysisResult.fromJson(Map<String, dynamic>.from(sample));
  }
}

/// Live backend: sends the photo to Google's Gemini vision API
/// (free tier — key from https://aistudio.google.com, no credit card)
/// and parses the strict-JSON listing it returns.
///
/// Any failure (network, bad key, unparsable response) throws
/// [AiServiceException] — the caller ([AppState]) falls back to
/// [MockAiService] so the demo never hard-crashes on a key problem.
class GeminiVisionService implements AiService {
  GeminiVisionService({
    required this.apiKey,
    this.model = 'gemini-2.5-flash',
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String apiKey;
  final String model;
  final http.Client _client;

  static const String _systemPrompt = """
You are Snap2Sell's listing expert. Given a photo of a household item someone
wants to resell, respond with ONLY a single JSON object (no markdown fences,
no commentary) with exactly these fields:
{
  "title": "short marketplace title, e.g. 'IKEA LACK Side Table — White'",
  "category": "one of: Furniture, Electronics, Appliances, Fashion, Toys & Games, Books & Media, Sports & Outdoors, Baby & Kids, Home & Garden, Miscellaneous",
  "condition": "one of: likeNew, excellent, good, fair, poor",
  "priceLow": number (low end of fair resale range, USD/CAD dollars),
  "priceHigh": number (high end of fair resale range),
  "suggestedPrice": number (list price: near the middle, rounded to a whole or .99 value),
  "description": "2-4 sentence marketplace description: what it is, condition honestly stated, notable inclusions, pickup/payment note"
}
Base the price range on typical second-hand marketplace values in North America.
If the photo is unclear, make your best guess and note the uncertainty in the description.
""";

  @override
  Future<AiAnalysisResult> analyzeItem(Uint8List photoBytes) async {
    try {
      final base64Image = base64Encode(photoBytes);
      final uri = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent',
      ).replace(queryParameters: {'key': apiKey});

      final response = await _client
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'contents': [
                {
                  'parts': [
                    {'text': '$_systemPrompt\n\nAnalyze this item and return the listing JSON.'},
                    {
                      'inline_data': {
                        'mime_type': 'image/jpeg',
                        'data': base64Image,
                      },
                    },
                  ],
                },
              ],
              'generationConfig': {
                'responseMimeType': 'application/json',
                'temperature': 0.2,
              },
            }),
          )
          .timeout(const Duration(seconds: 60));

      if (response.statusCode != 200) {
        throw AiServiceException(
          'Vision API returned HTTP ${response.statusCode}: ${response.body}',
        );
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final candidates = decoded['candidates'] as List<dynamic>?;
      if (candidates == null || candidates.isEmpty) {
        throw AiServiceException('Vision API returned no candidates.');
      }
      final content =
          (candidates.first as Map<String, dynamic>?)?['content']
              as Map<String, dynamic>?;
      final parts = content?['parts'] as List<dynamic>?;
      var text = ((parts?.first as Map<String, dynamic>?)?['text'] as String? ?? '').trim();
      if (text.isEmpty) {
        throw AiServiceException('Vision API returned an empty response.');
      }

      // Tolerate models that wrap JSON in ```json fences.
      if (text.startsWith('```')) {
        text = text.replaceAll(RegExp(r'^```(?:json)?'), '').replaceAll(
              RegExp(r'```$'),
              '',
            ).trim();
      }

      final listingJson = jsonDecode(text) as Map<String, dynamic>;
      return AiAnalysisResult.fromJson(listingJson);
    } on AiServiceException {
      rethrow;
    } catch (e) {
      throw AiServiceException('Could not analyze photo: $e');
    }
  }

  void dispose() => _client.close();
}
