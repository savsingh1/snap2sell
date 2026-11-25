// Perfection-loop app-side fixes.
//
// Covers the new backend contract:
// - rejection_reason / user_message / photo_mismatch_warning parsing
//   (present AND absent — older responses must parse identically).
// - Failure UX: the backend's user_message is shown for a rejection
//   instead of the generic clearer-photo guidance; the generic guidance
//   remains the fallback when no user_message is supplied.
// - Multi-photo mismatch is no longer a hard failure: the primary item's
//   listing is returned with a photo_mismatch_warning, surfaced in
//   AppState as a dismissible, non-blocking banner state.
// - A backend "Real Estate" category result reaches the review flow
//   (never blocked by the low-confidence gate) and the review screen
//   routes it to the property flow instead of a $0 product listing.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:snap2sell/models/ai_analysis_result.dart';
import 'package:snap2sell/models/item.dart';
import 'package:snap2sell/providers/app_state.dart';
import 'package:snap2sell/screens/results_screen.dart';
import 'package:snap2sell/services/ai_service.dart';
import 'package:snap2sell/services/real_estate/property_models.dart';
import 'package:snap2sell/services/real_estate/real_estate_ai_service.dart';
import 'package:snap2sell/services/real_estate/real_estate_detector.dart';

import 'backend_ai_service_test.dart'
    show makeTestJpeg, serviceWith, jsonResponse, ninjaIdentification;

const String kMismatchWarning =
    'One photo does not match: photo 2 shows a red bicycle, but the other '
    'photos show a Ninja blender. The listing below uses the blender — '
    'remove the bicycle photo before posting.';

/// Backend response under the NEW contract for a house photo: explicit
/// Real Estate category, no prices, more photos/details requested. The
/// title deliberately contains NO property keyword, so only the explicit
/// category can route it.
Map<String, dynamic> backendHouseIdentification() => {
      'recognized': true,
      'brand': '',
      'product_name': 'Residential Property',
      'model': '',
      'product_family': '',
      'category': 'Real Estate',
      'subcategory': '',
      'color': '',
      'condition': 'good',
      'visible_damage': [],
      'included_accessories': [],
      'missing_parts': [],
      'search_keywords': ['residential', 'property'],
      'suggested_title': 'Residential Property',
      'short_description':
          'A residential property photographed from the street.',
      'price_low': 0,
      'price_high': 0,
      'suggested_price': 0,
      'confidence': 90,
      'needs_more_photos': true,
      'recommended_photos': [
        'Add the property address',
        'Take interior photos',
      ],
    };

/// AiService double that always answers with the same result.
class _FixedAiService implements AiService {
  _FixedAiService(this.result);
  final AiAnalysisResult result;

  @override
  Future<AiAnalysisResult> analyzeItem(Uint8List photoBytes) async => result;

  @override
  Future<AiAnalysisResult> analyzeItems(List<Uint8List> photos) async =>
      result;
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

void main() {
  group('new contract fields: parsing', () {
    test('ProductIdentification parses all three fields when present', () {
      final id = ProductIdentification.fromJson(ninjaIdentification()
        ..['recognized'] = false
        ..['rejection_reason'] = 'blurry_image'
        ..['user_message'] = 'That photo is too blurry to identify.'
        ..['photo_mismatch_warning'] = kMismatchWarning);

      expect(id.rejectionReason, 'blurry_image');
      expect(id.userMessage, 'That photo is too blurry to identify.');
      expect(id.photoMismatchWarning, kMismatchWarning);
    });

    test('ProductIdentification defaults all three to empty when absent',
        () {
      // ninjaIdentification() is the OLD response shape — none of the new
      // keys exist. Parsing must behave exactly as before.
      final id = ProductIdentification.fromJson(ninjaIdentification());

      expect(id.rejectionReason, '');
      expect(id.userMessage, '');
      expect(id.photoMismatchWarning, '');
      expect(id.recognized, isTrue);
      expect(id.suggestedTitle, 'Ninja Countertop Blender — Black');
    });

    test('AiAnalysisResult.fromIdentification carries the mismatch warning',
        () {
      final id = ProductIdentification.fromJson(ninjaIdentification()
        ..['photo_mismatch_warning'] = kMismatchWarning);

      final result = AiAnalysisResult.fromIdentification(
        id,
        priceLow: 40,
        priceHigh: 70,
        suggestedPrice: 55,
      );

      expect(result.photoMismatchWarning, kMismatchWarning);
      expect(result.title, 'Ninja Countertop Blender — Black');
    });

    test('AiAnalysisResult JSON round-trips the warning; absent means empty',
        () {
      const withWarning = AiAnalysisResult(
        title: 't',
        category: 'Appliances',
        condition: ItemCondition.good,
        priceLow: 1,
        priceHigh: 2,
        suggestedPrice: 1.5,
        description: 'd',
        photoMismatchWarning: kMismatchWarning,
      );
      final restored = AiAnalysisResult.fromJson(withWarning.toJson());
      expect(restored.photoMismatchWarning, kMismatchWarning);

      const without = AiAnalysisResult(
        title: 't',
        category: 'Appliances',
        condition: ItemCondition.good,
        priceLow: 1,
        priceHigh: 2,
        suggestedPrice: 1.5,
        description: 'd',
      );
      expect(
          AiAnalysisResult.fromJson(without.toJson()).photoMismatchWarning,
          '');
      // JSON written before the field existed parses with the default.
      final oldJson = without.toJson()..remove('photoMismatchWarning');
      expect(AiAnalysisResult.fromJson(oldJson).photoMismatchWarning, '');
    });
  });

  group('failure UX: user_message selection', () {
    test('rejection shows the backend user_message, not generic guidance',
        () async {
      final id = ninjaIdentification(confidence: 10)
        ..['recognized'] = false
        ..['suggested_title'] = ''
        ..['product_name'] = ''
        ..['short_description'] = ''
        ..['price_low'] = 0
        ..['price_high'] = 0
        ..['suggested_price'] = 0
        ..['rejection_reason'] = 'non_product_image'
        ..['user_message'] =
            'That looks like a landscape, not an item for sale. Photograph the item itself, up close.'
        ..['recommended_photos'] = ['Take a photo of the front.'];
      final service =
          serviceWith(MockClient((_) async => jsonResponse(id, 200)));

      final err = await _captureError(() => service.analyzeItem(makeTestJpeg()));

      expect(err, isNotNull);
      expect(err!.category, AiErrorCategory.lowConfidence);
      // The backend's words win — even over the recommended-photos tips.
      expect(err.friendlyMessage,
          'That looks like a landscape, not an item for sale. Photograph the item itself, up close.');
    });

    test('rejection without user_message keeps the generic guidance',
        () async {
      final id = ninjaIdentification(confidence: 10)
        ..['recognized'] = false
        ..['recommended_photos'] = ['Take a photo of the model-number label.'];
      final service =
          serviceWith(MockClient((_) async => jsonResponse(id, 200)));

      final err = await _captureError(() => service.analyzeItem(makeTestJpeg()));

      expect(err, isNotNull);
      expect(err!.category, AiErrorCategory.lowConfidence);
      expect(err.friendlyMessage, contains('clearer photo'));
      expect(err.friendlyMessage, contains('model-number label'));
    });

    test('recognized result ignores user_message entirely', () async {
      // Defensive: a stray user_message on a successful response must not
      // turn a good listing into a failure.
      final id = ninjaIdentification()
        ..['user_message'] = 'should never be shown';
      final service =
          serviceWith(MockClient((_) async => jsonResponse(id, 200)));

      final result = await service.analyzeItem(makeTestJpeg());

      expect(result.title, 'Ninja Countertop Blender — Black');
    });
  });

  group('multi-photo mismatch: listing continues with a warning', () {
    test('analyzeItems returns the primary listing plus the warning',
        () async {
      final id = ninjaIdentification()
        ..['needs_more_photos'] = true
        ..['photo_mismatch_warning'] = kMismatchWarning;
      final service =
          serviceWith(MockClient((_) async => jsonResponse(id, 200)));

      // Under the OLD contract this shape (needs_more_photos) threw a
      // low-confidence failure. Now the listing must come through.
      final result = await service
          .analyzeItems([makeTestJpeg(), makeTestJpeg(), makeTestJpeg()]);

      expect(result.title, 'Ninja Countertop Blender — Black');
      expect(result.suggestedPrice, 55);
      expect(result.photoMismatchWarning, kMismatchWarning);
    });

    test('analyzeItem also passes a warning through', () async {
      final id = ninjaIdentification()
        ..['needs_more_photos'] = true
        ..['photo_mismatch_warning'] = kMismatchWarning;
      final service =
          serviceWith(MockClient((_) async => jsonResponse(id, 200)));

      final result = await service.analyzeItem(makeTestJpeg());

      expect(result.photoMismatchWarning, kMismatchWarning);
    });

    test('AppState exposes the warning as dismissible banner state',
        () async {
      const warningResult = AiAnalysisResult(
        title: 'Ninja Countertop Blender — Black',
        category: 'Appliances',
        condition: ItemCondition.good,
        priceLow: 40,
        priceHigh: 70,
        suggestedPrice: 55,
        description: 'desc',
        photoMismatchWarning: kMismatchWarning,
      );
      final appState = AppState(aiService: _FixedAiService(warningResult));

      await appState.analyzePhotoBytes(makeTestJpeg(),
          savedPath: '/tmp/loop-mismatch.jpg');

      // The listing was created AND the warning is up — no error, no block.
      expect(appState.analysisError, isNull);
      expect(appState.currentItem!.title,
          'Ninja Countertop Blender — Black');
      expect(appState.photoMismatchWarning, kMismatchWarning);

      appState.dismissPhotoMismatchWarning();
      expect(appState.photoMismatchWarning, isNull);
      // Dismissing never touches the listing.
      expect(appState.currentItem!.title,
          'Ninja Countertop Blender — Black');
    });

    test('AppState has no warning state when every photo matched', () async {
      const cleanResult = AiAnalysisResult(
        title: 'Ninja Countertop Blender — Black',
        category: 'Appliances',
        condition: ItemCondition.good,
        priceLow: 40,
        priceHigh: 70,
        suggestedPrice: 55,
        description: 'desc',
      );
      final appState = AppState(aiService: _FixedAiService(cleanResult));

      await appState.analyzePhotoBytes(makeTestJpeg(),
          savedPath: '/tmp/loop-clean.jpg');

      expect(appState.photoMismatchWarning, isNull);
      expect(appState.analysisError, isNull);
    });
  });

  group('Real Estate routing', () {
    test('backend service never blocks a Real Estate result', () async {
      // needs_more_photos=true would normally trip the low-confidence
      // gate; a property result must reach the review flow instead.
      final service = serviceWith(MockClient(
          (_) async => jsonResponse(backendHouseIdentification(), 200)));

      final result = await service.analyzeItem(makeTestJpeg());

      expect(result.category, 'Real Estate');
      expect(result.suggestedPrice, 0);
      expect(result.priceLow, 0);
      expect(result.priceHigh, 0);
    });

    test('detector bridge: explicit category routes without any keyword',
        () {
      const result = AiAnalysisResult(
        title: 'Residential Property',
        category: 'Real Estate',
        condition: ItemCondition.good,
        priceLow: 0,
        priceHigh: 0,
        suggestedPrice: 0,
        description: 'A residential property photographed from the street.',
      );

      expect(RealEstateDetector.detectFromResult(result),
          PropertyType.unknown);
      expect(RealEstateDetector.isRealEstate(result), isTrue);
    });

    test('detector bridge: keyword type still wins over the bridge', () {
      const result = AiAnalysisResult(
        title: 'Townhouse with garage',
        category: 'Real Estate',
        condition: ItemCondition.good,
        priceLow: 0,
        priceHigh: 0,
        suggestedPrice: 0,
        description: 'A residential property.',
      );

      expect(RealEstateDetector.detectFromResult(result),
          PropertyType.townhouse);
    });

    test('RealEstateAiService builds a report for the new backend shape',
        () async {
      final svc = RealEstateAiService(serviceWith(MockClient(
          (_) async => jsonResponse(backendHouseIdentification(), 200))));

      final result = await svc.analyzeItem(makeTestJpeg());

      expect(result.category, RealEstateAiService.realEstateCategory);
      expect(result.suggestedPrice, 0);
      final report = svc.lastPropertyReport;
      expect(report, isNotNull);
      expect(report!.record.propertyType, PropertyType.unknown);
      expect(report.addressConfirmed, isFalse);
      expect(report.nextStepMessage, contains('Add the property address'));
      expect(report.record.valuation.insufficientData, isTrue);
    });
  });

  group('ResultsScreen widgets', () {
    Future<AppState> analyzedState(AiAnalysisResult result) async {
      final appState = AppState(aiService: _FixedAiService(result));
      await appState.analyzePhotoBytes(makeTestJpeg(),
          savedPath: '/tmp/loop-widget.jpg');
      return appState;
    }

    Widget host(AppState appState) => ChangeNotifierProvider.value(
          value: appState,
          child: const MaterialApp(home: ResultsScreen()),
        );

    testWidgets('mismatch warning banners over a usable listing form',
        (tester) async {
      const result = AiAnalysisResult(
        title: 'Ninja Countertop Blender — Black',
        category: 'Appliances',
        condition: ItemCondition.good,
        priceLow: 40,
        priceHigh: 70,
        suggestedPrice: 55,
        description: 'desc',
        photoMismatchWarning: kMismatchWarning,
      );
      final appState = await tester.runAsync(() => analyzedState(result));
      await tester.pumpWidget(host(appState!));
      await tester.pumpAndSettle();

      // The backend's warning text is shown verbatim...
      expect(find.text(kMismatchWarning), findsOneWidget);

      // Dismissible: tapping the close control removes only the banner.
      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();
      expect(find.text(kMismatchWarning), findsNothing);
      expect(appState.photoMismatchWarning, isNull);

      // ...and the listing form underneath is fully present (not
      // blocked): scroll through it to prove both ends exist.
      await tester.scrollUntilVisible(find.text('Item title'), 120,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('Item title'), findsOneWidget);
      await tester.scrollUntilVisible(
          find.text('Continue to Platforms'), 120,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('Continue to Platforms'), findsOneWidget);
    });

    testWidgets('Real Estate result routes to the property panel, '
        'not a \$0 product listing', (tester) async {
      const result = AiAnalysisResult(
        title: 'Residential Property',
        category: 'Real Estate',
        condition: ItemCondition.good,
        priceLow: 0,
        priceHigh: 0,
        suggestedPrice: 0,
        description: 'A residential property photographed from the street.',
      );
      final appState = await tester.runAsync(() => analyzedState(result));
      await tester.pumpWidget(host(appState!));
      await tester.pumpAndSettle();

      // Explanation + property-flow entry are shown (scroll the panel
      // fully into view first — it sits below the photo preview)...
      await tester.scrollUntilVisible(
          find.text('This looks like a property'), 120,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('This looks like a property'), findsOneWidget);
      expect(
          find.textContaining(
              'A home valuation cannot be made from photos alone'),
          findsOneWidget);
      await tester.scrollUntilVisible(
          find.text('Open property valuation'), 120,
          scrollable: find.byType(Scrollable).first);
      // ...and the product-listing form is NOT presented, at any scroll
      // position of this short list.
      expect(find.text('Suggested price'), findsNothing);
      expect(find.text('Continue to Platforms'), findsNothing);
      expect(find.text('Item title'), findsNothing);

      // The button opens the existing property flow. (With an injected
      // test service there is no session report, so the property screen
      // shows its honest empty state — reports are session-scoped.)
      await tester.ensureVisible(find.text('Open property valuation'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open property valuation'));
      await tester.pumpAndSettle();
      expect(find.text('No property report for this item.'), findsOneWidget);
    });
  });
}
