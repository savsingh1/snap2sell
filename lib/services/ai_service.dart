import 'dart:math';
import 'dart:typed_data';

import '../models/ai_analysis_result.dart';
import 'backend_ai_service.dart';
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

/// Picks the right backend: the secure Snap2Sell analysis backend when its
/// URL is configured, otherwise the offline mock (the default — zero keys,
/// zero cost).
///
/// NOTE: the app intentionally NEVER talks to Google's Gemini API directly.
/// The Gemini API key lives in Secret Manager on the backend; the mobile app
/// only knows the backend URL. See [Snap2SellBackendService].
abstract final class AiServiceFactory {
  static AiService create() {
    if (AppConfig.hasAiBackend) {
      return Snap2SellBackendService(
        backendUrl: AppConfig.aiBackendUrl,
        appSecret: AppConfig.appApiSecret,
      );
    }
    return MockAiService();
  }
}

/// Offline demo backend. Returns realistic, varied listing data for common
/// household items so the whole app flow can be demoed with no backend.
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
