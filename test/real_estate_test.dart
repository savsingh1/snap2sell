// Real-estate / home-value analysis tests (Workstream B).
//
// These tests use CANNED backend responses (same pattern as the existing
// suite) — no live data is involved. The honesty assertions are the point:
// no test may pass while the code invents a price, an address, a
// comparable, or a renovation year.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:snap2sell/models/ai_analysis_result.dart';
import 'package:snap2sell/models/item.dart';
import 'package:snap2sell/services/real_estate/property_models.dart';
import 'package:snap2sell/services/real_estate/real_estate_ai_service.dart';
import 'package:snap2sell/services/real_estate/real_estate_analyzer.dart';
import 'package:snap2sell/services/real_estate/real_estate_detector.dart';
import 'package:snap2sell/services/real_estate/valuation_engine.dart';
import 'package:snap2sell/services/real_estate/visual_condition_analyzer.dart';

import 'backend_ai_service_test.dart'
    show makeTestJpeg, serviceWith, jsonResponse, ninjaIdentification;

/// Canned backend response for a residential-property photo, as the
/// deployed backend would return it (no Real Estate category yet — the
/// detector works off keywords).
Map<String, dynamic> houseIdentification({
  String productName = 'Detached house',
  int confidence = 88,
  String description =
      'Two-storey detached house with attached garage. Roof appears newer. '
          'Windows appear recently updated. Landscaping is maintained.',
}) =>
    {
      'recognized': true,
      'brand': '',
      'product_name': productName,
      'model': '',
      'product_family': '',
      'category': 'Miscellaneous',
      'subcategory': '',
      'color': '',
      'condition': 'good',
      'visible_damage': [],
      'included_accessories': [],
      'missing_parts': [],
      'search_keywords': ['house', 'detached', 'residential'],
      'suggested_title': productName,
      'short_description': description,
      'price_low': 0,
      'price_high': 0,
      'suggested_price': 0,
      'confidence': confidence,
      'needs_more_photos': false,
      'recommended_photos': [],
    };

/// Canned Apple product-family identification (Workstream A case) — must
/// NOT be flagged as real estate.
Map<String, dynamic> appleFamilyIdentification() => {
      'recognized': true,
      'brand': 'Apple',
      'product_name': 'MacBook Pro',
      'model': '',
      'product_family': 'MacBook Pro',
      'category': 'Electronics',
      'subcategory': '',
      'color': 'Space Gray',
      'condition': 'good',
      'visible_damage': [],
      'included_accessories': [],
      'missing_parts': [],
      'search_keywords': ['apple', 'macbook', 'laptop'],
      'suggested_title': 'Apple MacBook Pro',
      'short_description': 'Apple MacBook Pro. Year: Unknown.',
      'price_low': 0,
      'price_high': 0,
      'suggested_price': 0,
      'confidence': 92,
      'identification_level': 'product_family',
      'needs_more_information': true,
      'needs_more_photos': false,
      'recommended_photos': ['Take a photo of the model number.'],
    };

AiAnalysisResult _resultFrom(Map<String, dynamic> json) =>
    AiAnalysisResult.fromJson({
      'title': json['suggested_title'],
      'category': json['category'],
      'condition': json['condition'],
      'priceLow': json['price_low'],
      'priceHigh': json['price_high'],
      'suggestedPrice': json['suggested_price'],
      'description': json['short_description'],
    });

RealEstateAiService _reService(Map<String, dynamic> backendJson) =>
    RealEstateAiService(
        serviceWith(MockClient((_) async => jsonResponse(backendJson, 200))));

void main() {
  group('RealEstateDetector', () {
    test('detects a detached house photo', () {
      expect(
        RealEstateDetector.detectFromResult(
            _resultFrom(houseIdentification())),
        PropertyType.detachedHouse,
      );
    });

    test('detects condo / townhouse / duplex / acreage / lot', () {
      final cases = {
        'Condominium apartment': PropertyType.condo,
        'Downtown condo unit': PropertyType.condo,
        'Townhouse with garage': PropertyType.townhouse,
        'Half duplex': PropertyType.duplex,
        'Five acre acreage': PropertyType.acreage,
        'Vacant residential lot': PropertyType.residentialLot,
        'Triplex investment property': PropertyType.multiFamily,
        'Apartment building': PropertyType.apartment,
      };
      for (final entry in cases.entries) {
        expect(
          RealEstateDetector.detectFromResult(_resultFrom(
              houseIdentification(
                  productName: entry.key,
                  description: 'A residential property.'))),
          entry.value,
          reason: 'product name: ${entry.key}',
        );
      }
    });

    test('does not flag ordinary products (Ninja appliance)', () {
      expect(
        RealEstateDetector.detectFromResult(
            _resultFrom(ninjaIdentification())),
        isNull,
      );
    });

    test('does not flag Workstream A Apple family identification', () {
      expect(
        RealEstateDetector.detectFromResult(
            _resultFrom(appleFamilyIdentification())),
        isNull,
      );
    });

    test('word boundaries: dollhouse / warehouse are not houses', () {
      for (final title in ['Dollhouse miniature', 'Warehouse storage unit']) {
        expect(
          RealEstateDetector.detectFromResult(_resultFrom(
              houseIdentification(
                  productName: title,
                  description: 'A small item for sale.')
                ..['search_keywords'] = ['miniature'])),
          isNull,
          reason: 'title: $title',
        );
      }
    });
  });

  group('RealEstateAiService (photo-only mode)', () {
    test('house photo routes to real estate with NO invented value',
        () async {
      final svc = _reService(houseIdentification());
      final result = await svc.analyzeItem(makeTestJpeg());

      expect(result.category, RealEstateAiService.realEstateCategory);
      expect(result.pricingTier, 3);
      // No dollar value anywhere — not in prices, not in text.
      expect(result.priceLow, 0);
      expect(result.priceHigh, 0);
      expect(result.suggestedPrice, 0);
      expect(result.description.contains(RegExp(r'\$\d')), isFalse);

      final report = svc.lastPropertyReport;
      expect(report, isNotNull);
      expect(report!.record.propertyType, PropertyType.detachedHouse);
      // Photo-only: address is NEVER inferred.
      expect(report.record.address, isNull);
      expect(report.addressConfirmed, isFalse);
      expect(report.nextStepMessage, contains('Add the property address'));

      final v = report.record.valuation;
      expect(v.insufficientData, isTrue);
      expect(v.estimatedLow, isNull);
      expect(v.estimatedMid, isNull);
      expect(v.estimatedHigh, isNull);
      expect(v.confidence, ValuationConfidence.low);
      expect(v.reasons, isNotEmpty);
    });

    test('multi-photo analysis routes the same way', () async {
      final svc = _reService(houseIdentification());
      final photos = [makeTestJpeg(), makeTestJpeg()];
      final result = await svc.analyzeItems(photos);

      expect(result.category, RealEstateAiService.realEstateCategory);
      expect(svc.lastPropertyReport, isNotNull);
      expect(svc.lastPropertyReport!.record.valuation.insufficientData,
          isTrue);
    });

    test('non-real-estate passes through byte-identical (Ninja)', () async {
      final svc = _reService(ninjaIdentification());
      final result = await svc.analyzeItem(makeTestJpeg());

      expect(result.category, 'Appliances');
      expect(result.title, 'Ninja Countertop Blender — Black');
      expect(result.suggestedPrice, 55);
      expect(svc.lastPropertyReport, isNull);
    });

    test('attachAddress normalizes the record; providers stay honest',
        () async {
      final svc = _reService(houseIdentification());
      await svc.analyzeItem(makeTestJpeg());

      final updated = await svc.attachAddress(const PropertyAddress(
        street: '123 Main Street',
        city: 'Chilliwack',
      ));

      expect(updated.category, RealEstateAiService.realEstateCategory);
      final report = svc.lastPropertyReport!;
      expect(report.addressConfirmed, isTrue);
      expect(report.record.address!.street, '123 Main Street');
      expect(report.record.address!.city, 'Chilliwack');
      expect(report.record.address!.province, 'BC');

      // Every provider is a documented placeholder — the report says so.
      for (final note in report.dataSources) {
        if (note.sourceName.startsWith('Photo analysis')) {
          expect(note.isLive, isTrue);
        } else {
          expect(note.isLive, isFalse,
              reason: '${note.sourceName} must be marked placeholder');
          expect(note.detail, contains('To enable:'));
        }
      }
      // Still no invented numbers: assessment/permits/comps all absent,
      // valuation still honestly insufficient.
      expect(report.record.assessment, isNull);
      expect(report.record.permitHistory, isEmpty);
      expect(report.record.comparableSales, isEmpty);
      final v = report.record.valuation;
      expect(v.insufficientData, isTrue);
      expect(v.estimatedLow, isNull);
      expect(v.estimatedMid, isNull);
      expect(v.estimatedHigh, isNull);
    });

    test('attachAddress rejects an incomplete address', () async {
      final svc = _reService(houseIdentification());
      await svc.analyzeItem(makeTestJpeg());
      expect(
        () => svc.attachAddress(
            const PropertyAddress(street: '', city: 'Chilliwack')),
        throwsArgumentError,
      );
      // The photo-only report is untouched — still no address.
      expect(svc.lastPropertyReport!.addressConfirmed, isFalse);
    });

    test('clearReport drops the session report', () async {
      final svc = _reService(houseIdentification());
      await svc.analyzeItem(makeTestJpeg());
      expect(svc.lastPropertyReport, isNotNull);
      svc.clearReport();
      expect(svc.lastPropertyReport, isNull);
    });
  });

  group('RealEstateAnalyzer', () {
    test('user-supplied characteristics are labeled CONFIRMED BY USER',
        () async {
      final analyzer = RealEstateAnalyzer();
      final report = await analyzer.analyze(
        aiResult: _resultFrom(houseIdentification()),
        propertyType: PropertyType.detachedHouse,
        address: const PropertyAddress(
            street: '1 Test St', city: 'Chilliwack'),
        userCharacteristics: const PropertyCharacteristics(
          bedrooms: 4,
          bathrooms: 2.5,
          buildingAreaSqft: 2400,
          lotSizeSqft: 6000,
          evidence: RenovationEvidence.confirmedByUser,
        ),
      );
      expect(report.record.characteristics!.evidence,
          RenovationEvidence.confirmedByUser);
      expect(report.record.characteristics!.bedrooms, 4);
      // Still insufficient without authorized comps — user data alone
      // never conjures a market value.
      expect(report.record.valuation.insufficientData, isTrue);
      expect(report.record.valuation.estimatedMid, isNull);
    });

    test('renovation evidence labels are never merged', () async {
      final analyzer = RealEstateAnalyzer();
      final report = await analyzer.analyze(
        aiResult: _resultFrom(houseIdentification()),
        propertyType: PropertyType.detachedHouse,
        userRenovations: const [
          RenovationRecord(
            description: 'Finished basement',
            evidence: RenovationEvidence.confirmedByUser,
            sourceDetail: 'entered by owner',
          ),
        ],
      );
      final userOnes = report.record.knownRenovations
          .where((r) => r.evidence == RenovationEvidence.confirmedByUser);
      expect(userOnes.length, 1);
      // Photo observations stay observations — never promoted to records.
      for (final o in report.record.conditionObservations) {
        expect(o.evidence, RenovationEvidence.observedFromPhoto);
      }
      expect(
        report.record.knownRenovations
            .any((r) => r.evidence == RenovationEvidence.observedFromPhoto),
        isFalse,
      );
    });
  });

  group('PhotoConditionAnalyzer', () {
    test('never repeats a renovation year as fact', () {
      final analyzer = PhotoConditionAnalyzer();
      const result = AiAnalysisResult(
        title: 'Detached house',
        category: 'Miscellaneous',
        condition: ItemCondition.good,
        priceLow: 0,
        priceHigh: 0,
        suggestedPrice: 0,
        description:
            'Kitchen renovated in 2019. Roof appears newer. Windows appear recently updated.',
      );
      final obs = analyzer.analyze(result);
      expect(obs.any((o) => o.observation.contains('2019')), isFalse,
          reason: 'a photo cannot prove a renovation year');
      expect(
          obs.any((o) => o.observation.contains('Roof appears newer')), isTrue);
      expect(
          obs.any(
              (o) => o.observation.contains('Windows appear recently updated')),
          isTrue);
      for (final o in obs) {
        expect(o.evidence, RenovationEvidence.observedFromPhoto);
      }
    });

    test('overall condition always present, labeled as visual', () {
      final analyzer = PhotoConditionAnalyzer();
      const result = AiAnalysisResult(
        title: 'House',
        category: 'Miscellaneous',
        condition: ItemCondition.excellent,
        priceLow: 0,
        priceHigh: 0,
        suggestedPrice: 0,
        description: 'A house.',
      );
      final obs = analyzer.analyze(result);
      expect(obs.first.area, 'General');
      expect(obs.first.observation, contains('Excellent'));
    });
  });

  group('ValuationEngine', () {
    test('no data -> insufficient, nulls, LOW (never zeros)', () {
      final engine = ValuationEngine();
      final v = engine.estimate(
        propertyType: PropertyType.detachedHouse,
      );
      expect(v.insufficientData, isTrue);
      expect(v.estimatedLow, isNull);
      expect(v.estimatedMid, isNull);
      expect(v.estimatedHigh, isNull);
      expect(v.confidence, ValuationConfidence.low);
      expect(v.reasons.any((r) => r.contains('comparable')), isTrue);
    });

    test('three strong synthetic comps -> honest range, rounded', () {
      final engine = ValuationEngine();
      final v = engine.estimate(
        address:
            const PropertyAddress(street: '1 Test St', city: 'Chilliwack'),
        propertyType: PropertyType.detachedHouse,
        characteristics: const PropertyCharacteristics(
          bedrooms: 4,
          evidence: RenovationEvidence.confirmedByUser,
        ),
        comparables: const [
          ComparableSale(
              address: '2 Test St',
              salePrice: 900000,
              saleDate: '2026-09-01',
              similarityScore: 85),
          ComparableSale(
              address: '3 Test St',
              salePrice: 920000,
              saleDate: '2026-08-15',
              similarityScore: 82),
          ComparableSale(
              address: '4 Test St',
              salePrice: 890000,
              saleDate: '2026-09-20',
              similarityScore: 78),
        ],
      );
      expect(v.insufficientData, isFalse);
      expect(v.estimatedLow, isNotNull);
      expect(v.estimatedMid, isNotNull);
      expect(v.estimatedHigh, isNotNull);
      expect(v.estimatedLow! % 1000, 0);
      expect(v.estimatedMid! % 1000, 0);
      expect(v.estimatedHigh! % 1000, 0);
      expect(v.estimatedLow! <= v.estimatedMid!, isTrue);
      expect(v.estimatedMid! <= v.estimatedHigh!, isTrue);
      // Tight comps -> HIGH confidence per the spec criteria.
      expect(v.confidence, ValuationConfidence.high);
    });

    test('single comp -> very wide range, LOW confidence', () {
      final engine = ValuationEngine();
      final v = engine.estimate(
        address:
            const PropertyAddress(street: '1 Test St', city: 'Chilliwack'),
        propertyType: PropertyType.detachedHouse,
        comparables: const [
          ComparableSale(
              address: '2 Test St',
              salePrice: 900000,
              similarityScore: 80),
        ],
      );
      expect(v.insufficientData, isFalse);
      expect(v.confidence, ValuationConfidence.low);
      // ±25% of 900000, rounded.
      expect(v.estimatedLow, 675000);
      expect(v.estimatedHigh, 1125000);
      expect(v.reasons.any((r) => r.contains('3-sale minimum')), isTrue);
    });

    test('assessment alone never becomes a market value', () {      final engine = ValuationEngine();
      final v = engine.estimate(
        address:
            const PropertyAddress(street: '1 Test St', city: 'Chilliwack'),
        propertyType: PropertyType.detachedHouse,
        assessment: const AssessmentData(
          totalValue: 750000,
          assessmentYear: 2026,
        ),
      );
      // Assessment is a data input, not a market value: still insufficient.
      expect(v.insufficientData, isTrue);
      expect(v.estimatedMid, isNull);
    });

    test('recent subject sale is noted, never used as the value', () {
      final engine = ValuationEngine();
      final v = engine.estimate(
        address:
            const PropertyAddress(street: '1 Test St', city: 'Chilliwack'),
        propertyType: PropertyType.detachedHouse,
        comparables: const [
          ComparableSale(
              address: '2 Test St',
              salePrice: 900000,
              saleDate: '2026-09-01',
              similarityScore: 85),
          ComparableSale(
              address: '3 Test St',
              salePrice: 920000,
              saleDate: '2026-08-15',
              similarityScore: 82),
          ComparableSale(
              address: '4 Test St',
              salePrice: 890000,
              saleDate: '2026-09-20',
              similarityScore: 78),
        ],
        recentSales: [
          SubjectSale(
            salePrice: 895000,
            saleDate: DateTime.now().subtract(const Duration(days: 60)),
            sourceLabel: 'test',
          ),
        ],
      );
      expect(v.insufficientData, isFalse);
      // The range still comes from the comps, not the subject sale.
      expect(v.estimatedMid, 900000);
      expect(
          v.reasons.any((r) =>
              r.contains('Subject sold for') && r.contains('within')),
          isTrue);
    });
  });
}
