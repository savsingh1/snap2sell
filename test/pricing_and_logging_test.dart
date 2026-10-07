import 'package:flutter_test/flutter_test.dart';
import 'package:snap2sell/models/ai_analysis_result.dart';
import 'package:snap2sell/services/ai_logger.dart';
import 'package:snap2sell/services/pricing_service.dart';

ProductIdentification _id({
  double low = 40,
  double high = 70,
  double suggested = 55,
}) =>
    ProductIdentification(
      recognized: true,
      brand: 'Ninja',
      productName: 'Countertop Blender',
      model: '',
      productFamily: 'blender',
      category: 'Appliances',
      subcategory: 'Blenders',
      color: 'Black',
      condition: 'good',
      visibleDamage: const [],
      includedAccessories: const ['pitcher'],
      missingParts: const [],
      searchKeywords: const ['ninja', 'blender'],
      suggestedTitle: 'Ninja Countertop Blender — Black',
      shortDescription: 'A blender.',
      priceLow: low,
      priceHigh: high,
      suggestedPrice: suggested,
      confidence: 85,
      needsMorePhotos: false,
      recommendedPhotos: const [],
    );

void main() {
  group('AiEstimatePricingService', () {
    final pricing = AiEstimatePricingService();

    test('passes the AI range through, labeled as an estimate', () {
      final estimate = pricing.estimatePrice(_id());

      expect(estimate.low, 40);
      expect(estimate.high, 70);
      expect(estimate.suggested, 55);
      expect(estimate.source, 'ai-estimate');
    });

    test('zero prices stay zero (never invents a price)', () {
      final estimate = pricing.estimatePrice(_id(low: 0, high: 0, suggested: 0));

      expect(estimate.low, 0);
      expect(estimate.high, 0);
      expect(estimate.suggested, 0);
    });

    test('missing suggested price falls back to the range midpoint', () {
      final estimate = pricing.estimatePrice(_id(suggested: 0));

      expect(estimate.suggested, 55);
    });
  });

  group('AiLogger.redact', () {
    test('masks key= credentials', () {
      expect(
        AiLogger.redact('failed uri=https://x.test/?key=AIzaSySECRET123'),
        isNot(contains('AIzaSySECRET123')),
      );
      expect(AiLogger.redact('key=AIzaSySECRET123'), contains('key=***'));
    });

    test('leaves ordinary text alone', () {
      expect(AiLogger.redact('analysis_ok confidence=85'), 'analysis_ok confidence=85');
    });
  });

  group('ProductIdentification.fromJson', () {
    test('clamps confidence to 0..100 and tolerates missing fields', () {
      final id = ProductIdentification.fromJson({
        'confidence': 250,
        'brand': '  Ninja ',
      });

      expect(id.confidence, 100);
      expect(id.brand, 'Ninja');
      expect(id.productName, '');
      expect(id.recommendedPhotos, isEmpty);
      expect(id.recognized, isFalse);
    });
  });
}
