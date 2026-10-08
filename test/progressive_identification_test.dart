import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:snap2sell/models/ai_analysis_result.dart';
import 'package:snap2sell/models/item.dart';
import 'package:snap2sell/providers/app_state.dart';
import 'package:snap2sell/services/ai_service.dart';
import 'package:snap2sell/services/pricing_service.dart';

import 'backend_ai_service_test.dart'
    show makeTestJpeg, serviceWith, jsonResponse;

/// Canned backend response for an Apple/Tesla product-family identification:
/// brand + family known, exact variant unknown (the case the patch targets).
Map<String, dynamic> _familyId({
  required String brand,
  required String productName,
  required int confidence,
  bool needsMorePhotos = true,
  List<String> recommendedPhotos = const ['Take a photo of the model number.'],
  String identificationLevel = '',
  bool needsMoreInformation = false,
  double low = 0,
  double high = 0,
  double suggested = 0,
  bool recognized = true,
}) =>
    {
      'recognized': recognized,
      'brand': brand,
      'product_name': productName,
      'model': '',
      'product_family': productName,
      'category': brand == 'Tesla' ? 'Miscellaneous' : 'Electronics',
      'subcategory': '',
      'color': 'Space Gray',
      'condition': 'good',
      'visible_damage': [],
      'included_accessories': [],
      'missing_parts': [],
      'search_keywords': [],
      'suggested_title': '$brand $productName',
      'short_description':
          '$brand $productName. Year: Unknown. Chip: Unknown. Storage: Unknown. Model number: Unknown.',
      'price_low': low,
      'price_high': high,
      'suggested_price': suggested,
      'confidence': confidence,
      'identification_level': identificationLevel,
      'needs_more_information': needsMoreInformation,
      'needs_more_photos': needsMorePhotos,
      'recommended_photos': recommendedPhotos,
    };

/// Exact pre-patch outputs recorded from the production baseline
/// (rollback/workstream-a-20261007/baseline-before.json). Any change here
/// is a regression.
const Map<String, Map<String, dynamic>> _baselineExpectations = {
  'ninja': {
    'title': 'Ninja Countertop Blender — Black',
    'category': 'Appliances',
    'priceLow': 40.0,
    'priceHigh': 70.0,
    'suggestedPrice': 55.0,
    'description':
        'Ninja countertop blender in black with pitcher and lid. Powers on per seller; sold as-is, please confirm condition. (AI estimate — please confirm details before listing.)',
  },
  'volkswagen': {
    'title': 'Volkswagen Golf',
    'category': 'Miscellaneous',
    'priceLow': 8500.0,
    'priceHigh': 10500.0,
    'suggestedPrice': 9500.0,
    'description': 'A Golf. (AI estimate — please confirm details before listing.)',
  },
  'kia': {
    'title': 'Kia Sportage',
    'category': 'Miscellaneous',
    'priceLow': 16000.0,
    'priceHigh': 19000.0,
    'suggestedPrice': 17500.0,
    'description':
        'A Sportage. (AI estimate — please confirm details before listing.)',
  },
  'toaster': {
    'title': 'Black+Decker 2-Slice Toaster',
    'category': 'Appliances',
    'priceLow': 12.0,
    'priceHigh': 22.0,
    'suggestedPrice': 17.0,
    'description':
        'A 2-Slice Toaster. (AI estimate — please confirm details before listing.)',
  },
  'headphones': {
    'title': 'Sony WH-1000XM4 Wireless Headphones',
    'category': 'Electronics',
    'priceLow': 120.0,
    'priceHigh': 180.0,
    'suggestedPrice': 150.0,
    'description':
        'A WH-1000XM4 Wireless Headphones. (AI estimate — please confirm details before listing.)',
  },
};

Map<String, dynamic> _baselineId(String key) {
  switch (key) {
    case 'ninja':
      return {
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
        'confidence': 85,
        'needs_more_photos': false,
        'recommended_photos': [],
      };
    case 'volkswagen':
      return _simpleVehicle('Volkswagen', 'Golf', '2019 Golf TSI', 88,
          low: 8500, high: 10500, suggested: 9500);
    case 'kia':
      return _simpleVehicle('Kia', 'Sportage', '2021 Sportage LX', 84,
          low: 16000, high: 19000, suggested: 17500);
    case 'toaster':
      return {
        'recognized': true,
        'brand': 'Black+Decker',
        'product_name': '2-Slice Toaster',
        'model': '',
        'product_family': 'toaster',
        'category': 'Appliances',
        'subcategory': '',
        'color': '',
        'condition': 'good',
        'visible_damage': [],
        'included_accessories': [],
        'missing_parts': [],
        'search_keywords': [],
        'suggested_title': 'Black+Decker 2-Slice Toaster',
        'short_description': 'A 2-Slice Toaster.',
        'price_low': 12,
        'price_high': 22,
        'suggested_price': 17,
        'confidence': 81,
        'needs_more_photos': false,
        'recommended_photos': [],
      };
    default: // headphones
      return {
        'recognized': true,
        'brand': 'Sony',
        'product_name': 'WH-1000XM4 Wireless Headphones',
        'model': 'WH-1000XM4',
        'product_family': '',
        'category': 'Electronics',
        'subcategory': '',
        'color': '',
        'condition': 'good',
        'visible_damage': [],
        'included_accessories': [],
        'missing_parts': [],
        'search_keywords': [],
        'suggested_title': 'Sony WH-1000XM4 Wireless Headphones',
        'short_description': 'A WH-1000XM4 Wireless Headphones.',
        'price_low': 120,
        'price_high': 180,
        'suggested_price': 150,
        'confidence': 90,
        'needs_more_photos': false,
        'recommended_photos': [],
      };
  }
}

Map<String, dynamic> _simpleVehicle(String brand, String productName,
    String model, int confidence,
    {required double low, required double high, required double suggested}) {
  return {
    'recognized': true,
    'brand': brand,
    'product_name': productName,
    'model': model,
    'product_family': productName,
    'category': 'Miscellaneous',
    'subcategory': '',
    'color': '',
    'condition': 'good',
    'visible_damage': [],
    'included_accessories': [],
    'missing_parts': [],
    'search_keywords': [],
    'suggested_title': '$brand $productName',
    'short_description': 'A $productName.',
    'price_low': low,
    'price_high': high,
    'suggested_price': suggested,
    'confidence': confidence,
    'needs_more_photos': false,
    'recommended_photos': [],
  };
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

Uint8List _realPhotoBytes() {
  final image = img.Image(width: 64, height: 64);
  img.fill(image, color: img.ColorRgb8(200, 150, 100));
  return Uint8List.fromList(img.encodeJpg(image, quality: 90));
}

/// AiService stub returning a fixed listing with a partial-identification
/// notice, to verify AppState surfaces/dismisses the banner state.
class _PartialNoticeAiService implements AiService {
  @override
  Future<AiAnalysisResult> analyzeItem(Uint8List photoBytes) async =>
      const AiAnalysisResult(
        title: 'Apple MacBook Pro',
        category: 'Electronics',
        condition: ItemCondition.good,
        priceLow: 400,
        priceHigh: 1100,
        suggestedPrice: 750,
        description: 'Apple MacBook Pro.',
        identificationLevel: 'product_family',
        pricingTier: 2,
        partialNotice: 'Product identified: Apple MacBook Pro.',
      );

  @override
  Future<AiAnalysisResult> analyzeItems(List<Uint8List> photos) =>
      analyzeItem(photos.first);
}

void main() {
  group('Apple progressive identification', () {
    test('MacBook Pro, exact model unknown: listing continues (no hard block)',
        () async {
      final service = serviceWith(MockClient((_) async => jsonResponse(
          _familyId(
              brand: 'Apple',
              productName: 'MacBook Pro',
              confidence: 92,
              low: 400,
              high: 1100),
          200)));

      final result = await service.analyzeItem(makeTestJpeg());

      expect(result.title, 'Apple MacBook Pro');
      expect(result.category, 'Electronics');
      expect(result.identificationLevel, 'product_family');
      expect(result.pricingTier, 2);
      // Tier 2: broader range labeled preliminary, never a fake exact price.
      expect(result.priceLow, 400);
      expect(result.priceHigh, 1100);
      expect(result.description, contains('Preliminary estimated resale range'));
      expect(result.description,
          contains('confirm the model/year for a more accurate estimate'));
      // Honesty: no year/chip/storage/model number invented.
      expect(result.title.contains(RegExp(r'\b(19|20)\d{2}\b')), isFalse);
      expect(result.title.contains(RegExp(r'A\d{4}')), isFalse);
      expect(result.description, contains('Unknown'));
      // Soft notice instead of the hard block.
      expect(result.partialNotice, isNotNull);
      expect(result.partialNotice, contains('Product identified: Apple MacBook Pro'));
      expect(result.partialNotice, contains('We can create your listing now'));
      expect(result.partialNotice, contains('model number'));
    });

    test('new backend fields (identification_level/needs_more_information)',
        () async {
      final service = serviceWith(MockClient((_) async => jsonResponse(
          _familyId(
            brand: 'Apple',
            productName: 'MacBook Pro',
            confidence: 88,
            needsMorePhotos: false,
            identificationLevel: 'product_family',
            needsMoreInformation: true,
            low: 350,
            high: 1200,
          ),
          200)));

      final result = await service.analyzeItem(makeTestJpeg());

      expect(result.identificationLevel, 'product_family');
      expect(result.pricingTier, 2);
      expect(result.partialNotice, isNotNull);
      expect(result.description, contains('Preliminary estimated resale range'));
    });

    test('Apple family with no usable prices: tier 3, honest label, no number',
        () async {
      final service = serviceWith(MockClient((_) async => jsonResponse(
          _familyId(
              brand: 'Apple', productName: 'iPad Air', confidence: 90),
          200)));

      final result = await service.analyzeItem(makeTestJpeg());

      expect(result.title, 'Apple iPad Air');
      expect(result.pricingTier, 3);
      expect(result.priceLow, 0);
      expect(result.priceHigh, 0);
      expect(result.suggestedPrice, 0);
      expect(
          result.description, contains('Exact pricing requires the model/year.'));
      expect(result.partialNotice, isNotNull);
      expect(result.partialNotice, contains('Product identified: Apple iPad Air'));
    });

    test('all Apple families: MacBook Air, iPad, iPad Pro, iPad Air',
        () async {
      for (final family in [
        'MacBook Air',
        'iPad',
        'iPad Pro',
        'iPad Air',
      ]) {
        final service = serviceWith(MockClient((_) async => jsonResponse(
            _familyId(
                brand: 'Apple',
                productName: family,
                confidence: 91,
                low: 200,
                high: 600),
            200)));
        final result = await service.analyzeItem(makeTestJpeg());
        expect(result.title, 'Apple $family', reason: family);
        expect(result.identificationLevel, 'product_family', reason: family);
        expect(result.pricingTier, 2, reason: family);
        expect(result.partialNotice, contains('Product identified: Apple $family'),
            reason: family);
      }
    });

    test('Apple exact identification (model known): tier 1, no notice',
        () async {
      final id = _familyId(
          brand: 'Apple',
          productName: 'MacBook Pro',
          confidence: 95,
          needsMorePhotos: false,
          low: 900,
          high: 1100,
          suggested: 1000)
        ..['model'] = 'A2338';
      final service =
          serviceWith(MockClient((_) async => jsonResponse(id, 200)));

      final result = await service.analyzeItem(makeTestJpeg());

      expect(result.identificationLevel, 'exact');
      expect(result.pricingTier, 1);
      expect(result.partialNotice, isNull);
      expect(result.description, isNot(contains('Preliminary')));
    });

    test('Apple with genuinely low confidence still asks for a clearer photo',
        () async {
      final service = serviceWith(MockClient((_) async => jsonResponse(
          _familyId(
              brand: 'Apple',
              productName: 'MacBook Pro',
              confidence: 45,
              recognized: false),
          200)));

      final err =
          await _captureError(() => service.analyzeItem(makeTestJpeg()));

      expect(err, isNotNull);
      expect(err!.category, AiErrorCategory.lowConfidence);
      expect(err.friendlyMessage, contains('clearer photo'));
    });
  });

  group('Tesla progressive identification', () {
    test('Model 3/Y/S/X: family identified, no trim/year invented', () async {
      for (final model in ['Model 3', 'Model Y', 'Model S', 'Model X']) {
        final service = serviceWith(MockClient((_) async => jsonResponse(
            _familyId(
              brand: 'Tesla',
              productName: model,
              confidence: 89,
              recommendedPhotos: ['Take a photo of the VIN plate.'],
              low: 20000,
              high: 35000,
            ),
            200)));
        final result = await service.analyzeItem(makeTestJpeg());
        expect(result.title, 'Tesla $model', reason: model);
        expect(result.identificationLevel, 'product_family', reason: model);
        expect(result.pricingTier, 2, reason: model);
        // No year/trim/battery/drivetrain invented.
        expect(result.title.contains(RegExp(r'\b(19|20)\d{2}\b')), isFalse,
            reason: model);
        expect(result.title.toLowerCase(), isNot(contains('long range')),
            reason: model);
        expect(result.title.toLowerCase(), isNot(contains('performance')),
            reason: model);
        expect(result.partialNotice,
            contains('Product identified: Tesla $model'),
            reason: model);
        expect(result.partialNotice, contains('VIN'), reason: model);
        expect(result.description, contains('Preliminary estimated resale range'),
            reason: model);
      }
    });

    test('Tesla with new backend fields continues the listing', () async {
      final service = serviceWith(MockClient((_) async => jsonResponse(
          _familyId(
            brand: 'Tesla',
            productName: 'Model 3',
            confidence: 90,
            needsMorePhotos: false,
            identificationLevel: 'product_family',
            needsMoreInformation: true,
          ),
          200)));

      final result = await service.analyzeItem(makeTestJpeg());

      expect(result.title, 'Tesla Model 3');
      expect(result.pricingTier, 3); // no prices -> tier 3, zeros kept
      expect(result.suggestedPrice, 0);
      expect(
          result.description, contains('Exact pricing requires the model/year.'));
      expect(result.partialNotice, isNotNull);
    });
  });

  group('brand gate does not leak to other products', () {
    test('Volkswagen asking for more photos still gets the clearer-photo ask',
        () async {
      final id = _simpleVehicle('Volkswagen', 'Golf', '', 88,
          low: 8500, high: 10500, suggested: 9500)
        ..['needs_more_photos'] = true
        ..['recommended_photos'] = ['Take a photo of the badge.'];
      final service =
          serviceWith(MockClient((_) async => jsonResponse(id, 200)));

      final err =
          await _captureError(() => service.analyzeItem(makeTestJpeg()));

      expect(err, isNotNull);
      expect(err!.category, AiErrorCategory.lowConfidence);
    });

    test('non-Apple/Tesla weak result: no partial notice, no tier change',
        () async {
      final id = Map<String, dynamic>.from(_baselineId('ninja'));
      final parsed = ProductIdentification.fromJson(id);
      expect(ProgressiveIdentification.matchedFamily(parsed), isNull);
      expect(ProgressiveIdentification.levelOf(parsed), 'exact');
      expect(ProgressiveIdentification.noticeFor(parsed), isNull);
      expect(AiEstimatePricingService().estimatePrice(parsed).tier, 1);
    });
  });

  group('regression: production baseline outputs unchanged', () {
    for (final key in _baselineExpectations.keys) {
      test('$key matches the pre-patch baseline', () async {
        final service = serviceWith(
            MockClient((_) async => jsonResponse(_baselineId(key), 200)));

        final result = await service.analyzeItem(makeTestJpeg());
        final expected = _baselineExpectations[key]!;

        expect(result.title, expected['title']);
        expect(result.category, expected['category']);
        expect(result.priceLow, expected['priceLow']);
        expect(result.priceHigh, expected['priceHigh']);
        expect(result.suggestedPrice, expected['suggestedPrice']);
        expect(result.description, expected['description']);
        // No new labeling leaks into untouched categories.
        expect(result.identificationLevel, 'exact');
        expect(result.pricingTier, 1);
        expect(result.partialNotice, isNull);
      });
    }
  });

  group('AppState surfaces the partial-identification notice', () {
    test('partialNotice set after analysis, dismissible', () async {
      final appState = AppState(aiService: _PartialNoticeAiService());

      await appState.analyzePhotoBytes(
        _realPhotoBytes(),
        savedPath: '/tmp/macbook.jpg',
      );

      expect(appState.currentItem, isNotNull);
      expect(appState.currentItem!.title, 'Apple MacBook Pro');
      expect(appState.analysisError, isNull);
      expect(appState.partialNotice,
          contains('Product identified: Apple MacBook Pro'));

      appState.dismissPartialNotice();
      expect(appState.partialNotice, isNull);
      // The listing survives dismissal.
      expect(appState.currentItem!.title, 'Apple MacBook Pro');
    });
  });
}
