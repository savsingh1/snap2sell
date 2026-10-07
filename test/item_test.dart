import 'package:flutter_test/flutter_test.dart';
import 'package:snap2sell/models/ai_analysis_result.dart';
import 'package:snap2sell/models/item.dart';
import 'package:snap2sell/services/listing_service.dart';

void main() {
  group('Item JSON round-trip', () {
    test('toJson/fromJson preserves every field', () {
      final item = Item(
        id: 'abc123',
        photoPath: '/tmp/photo.jpg',
        title: 'IKEA LACK Side Table — White',
        category: 'Furniture',
        condition: ItemCondition.good,
        priceLow: 8,
        priceHigh: 18,
        suggestedPrice: 12,
        description: 'Sturdy little table.',
        platforms: ['Facebook Marketplace', 'eBay'],
        status: ListingStatus.ready,
        createdAt: DateTime.utc(2026, 10, 6, 12, 0, 0),
      );

      final restored = Item.fromJson(item.toJson());

      expect(restored.id, 'abc123');
      expect(restored.photoPath, '/tmp/photo.jpg');
      expect(restored.title, 'IKEA LACK Side Table — White');
      expect(restored.category, 'Furniture');
      expect(restored.condition, ItemCondition.good);
      expect(restored.priceLow, 8);
      expect(restored.priceHigh, 18);
      expect(restored.suggestedPrice, 12);
      expect(restored.description, 'Sturdy little table.');
      expect(restored.platforms, ['Facebook Marketplace', 'eBay']);
      expect(restored.status, ListingStatus.ready);
      expect(restored.createdAt, DateTime.utc(2026, 10, 6, 12, 0, 0));
    });

    test('fromJson tolerates missing/legacy fields', () {
      final restored = Item.fromJson({
        'id': 'x',
        'photoPath': '/p.jpg',
      });
      expect(restored.title, '');
      expect(restored.condition, ItemCondition.good);
      expect(restored.status, ListingStatus.draft);
      expect(restored.platforms, isEmpty);
    });

    test('copyWith overrides only the given fields', () {
      final item = Item(
        id: 'x',
        photoPath: '/p.jpg',
        title: 'Old',
        category: 'Miscellaneous',
        condition: ItemCondition.fair,
        priceLow: 1,
        priceHigh: 2,
        suggestedPrice: 1.5,
        description: 'd',
      );
      final updated = item.copyWith(title: 'New', status: ListingStatus.sold);
      expect(updated.title, 'New');
      expect(updated.status, ListingStatus.sold);
      expect(updated.id, 'x');
      expect(updated.condition, ItemCondition.fair);
    });
  });

  group('Condition / status labels', () {
    test('every enum value has a label and round-trips', () {
      for (final c in ItemCondition.values) {
        expect(c.label, isNotEmpty);
        expect(
          ItemConditionLabel.fromString(c.name),
          c,
        );
      }
      for (final s in ListingStatus.values) {
        expect(s.label, isNotEmpty);
        expect(
          ListingStatusLabel.fromString(s.name),
          s,
        );
      }
      expect(ItemConditionLabel.fromString('bogus'), ItemCondition.good);
    });
  });

  group('AiAnalysisResult', () {
    test('fromJson parses the OpenAI-style payload', () {
      final result = AiAnalysisResult.fromJson({
        'title': 'Dyson V8',
        'category': 'Appliances',
        'condition': 'excellent',
        'priceLow': 140,
        'priceHigh': 210,
        'suggestedPrice': 175,
        'description': 'Works great.',
      });
      expect(result.title, 'Dyson V8');
      expect(result.condition, ItemCondition.excellent);
      expect(result.suggestedPrice, 175);
    });
  });

  group('ListingService', () {
    final service = ListingService();
    final item = Item(
      id: 'x',
      photoPath: '/p.jpg',
      title: 'Nike Pegasus — Size 10',
      category: 'Fashion',
      condition: ItemCondition.likeNew,
      priceLow: 45,
      priceHigh: 75,
      suggestedPrice: 60,
      description: 'Worn twice.',
    );

    test('buildListingText contains the essentials', () {
      final text = service.buildListingText(item);
      expect(text, contains('Nike Pegasus — Size 10'));
      expect(text, contains('\$60'));
      expect(text, contains('Like New'));
      expect(text, contains('Worn twice.'));
      expect(text, contains('Snap2Sell'));
    });

    test('buildShortText is a one-liner', () {
      final text = service.buildShortText(item);
      expect(text, isNot(contains('\n')));
      expect(text, contains('\$60'));
    });
  });
}
