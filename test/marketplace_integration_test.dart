import 'package:flutter_test/flutter_test.dart';
import 'package:snap2sell/models/item.dart';
import 'package:snap2sell/services/ebay_listing_service.dart';
import 'package:snap2sell/services/facebook_auth_service.dart';
import 'package:snap2sell/services/facebook_catalog_service.dart';
import 'package:snap2sell/services/marketplace_handoff.dart';
import 'package:snap2sell/services/sell_destination.dart';

Item _item({
  ItemCondition condition = ItemCondition.good,
  List<String> extraPhotoPaths = const [],
}) {
  return Item(
    id: 'itm_42',
    photoPath: '/tmp/main.jpg',
    extraPhotoPaths: extraPhotoPaths,
    title: 'IKEA LACK Side Table — White',
    category: 'Furniture',
    condition: condition,
    priceLow: 8,
    priceHigh: 18,
    suggestedPrice: 12,
    description: 'Sturdy little table. Pickup in Chilliwack.',
  );
}

void main() {
  group('Marketplace handoff — clipboard text', () {
    final handoff = MarketplaceHandoffService();

    test('formats title, price, condition, description exactly', () {
      expect(
        handoff.buildHandoffText(_item()),
        'IKEA LACK Side Table — White\n'
        'Price: \$12\n'
        'Condition: Good\n'
        '\n'
        'Sturdy little table. Pickup in Chilliwack.',
      );
    });

    test('uses whole-dollar price and the item condition label', () {
      final text = handoff.buildHandoffText(
        _item(condition: ItemCondition.likeNew),
      );
      expect(text, contains('Price: \$12'));
      expect(text, contains('Condition: Like New'));
    });

    test('carries no Snap2Sell footer that would need deleting', () {
      expect(handoff.buildHandoffText(_item()),
          isNot(contains('Listed with Snap2Sell')));
    });
  });

  group('Marketplace handoff — intent construction', () {
    final handoff = MarketplaceHandoffService();

    test('deep-links to the official Marketplace create flow', () {
      final intent = handoff.buildIntent(_item());
      expect(
        intent.createListingUri.toString(),
        'https://www.facebook.com/marketplace/create/item',
      );
    });

    test('includes main photo first, then extras, in share order', () {
      final intent = handoff.buildIntent(
        _item(extraPhotoPaths: ['/tmp/extra1.jpg', '/tmp/extra2.jpg']),
      );
      expect(
        intent.photoPaths,
        ['/tmp/main.jpg', '/tmp/extra1.jpg', '/tmp/extra2.jpg'],
      );
    });

    test('single-photo listings hand off just the main photo', () {
      expect(handoff.buildIntent(_item()).photoPaths, ['/tmp/main.jpg']);
    });

    test('intent clipboard text matches the standalone builder', () {
      final item = _item();
      expect(
        handoff.buildIntent(item).clipboardText,
        handoff.buildHandoffText(item),
      );
    });

    test('designed steps explain the whole flow to the seller', () {
      final steps = handoff.buildIntent(_item()).designedSteps;
      expect(steps.length, 4);
      expect(steps.first, contains('copies your listing text'));
      expect(steps.last, contains('Publish'));
    });
  });

  group('Facebook auth — honest not-configured state', () {
    test('no app id → notConfigured, connect fails with setup message',
        () async {
      final auth = ConfigGatedFacebookAuthService(appId: '');
      expect(auth.isConfigured, isFalse);
      expect(auth.state, FacebookConnectionState.notConfigured);
      expect(auth.connectedUserName, isNull);

      final result = await auth.connect();
      expect(result.ok, isFalse);
      expect(result.message,
          ConfigGatedFacebookAuthService.notConfiguredMessage);
      // A failed connect must never flip state to connected.
      expect(auth.state, FacebookConnectionState.notConfigured);
    });

    test('app id present but SDK unwired → disconnected, still no fake '
        'connection', () async {
      final auth = ConfigGatedFacebookAuthService(appId: '1234567890');
      expect(auth.isConfigured, isTrue);
      expect(auth.state, FacebookConnectionState.disconnected);

      final result = await auth.connect();
      expect(result.ok, isFalse);
      expect(
          result.message, ConfigGatedFacebookAuthService.sdkNotWiredMessage);
      expect(auth.state, FacebookConnectionState.disconnected);
      expect(auth.connectedUserName, isNull);
    });

    test('disconnect is a safe no-op when never connected', () async {
      final auth = ConfigGatedFacebookAuthService(appId: '');
      await auth.disconnect();
      expect(auth.state, FacebookConnectionState.notConfigured);
    });
  });

  group('Facebook Catalog payload builder', () {
    final catalog = FacebookCatalogService();
    const images = [
      'https://cdn.example.com/a.jpg',
      'https://cdn.example.com/b.jpg',
    ];

    test('destination name and permissions are the business route', () {
      expect(catalog.destinationName, 'Facebook Shop (Catalog)');
      expect(
        FacebookCatalogService.requiredPermissions,
        ['catalog_management', 'business_management'],
      );
    });

    test('product fields carry title, price, availability, images', () {
      final fields = catalog.buildProductFields(_item(), imageUrls: images);
      expect(fields['retailer_id'], 'snap2sell_itm_42');
      expect(fields['title'], 'IKEA LACK Side Table — White');
      expect(fields['description'],
          'Sturdy little table. Pickup in Chilliwack.');
      expect(fields['availability'], 'in stock');
      expect(fields['price'], '12.00 USD');
      expect(fields['image_url'], 'https://cdn.example.com/a.jpg');
      expect(fields['additional_image_urls'],
          ['https://cdn.example.com/b.jpg']);
    });

    test('single image produces no additional_image_urls key', () {
      final fields = catalog.buildProductFields(
        _item(),
        imageUrls: ['https://cdn.example.com/a.jpg'],
      );
      expect(fields.containsKey('additional_image_urls'), isFalse);
    });

    test('hosted image URLs are mandatory', () {
      expect(
        () => catalog.buildProductFields(_item(), imageUrls: const []),
        throwsArgumentError,
      );
    });

    test('condition mapping follows Meta catalog values', () {
      expect(FacebookCatalogService.mapCondition(ItemCondition.likeNew),
          'used_like_new');
      expect(FacebookCatalogService.mapCondition(ItemCondition.excellent),
          'used_good');
      expect(FacebookCatalogService.mapCondition(ItemCondition.good),
          'used_good');
      expect(FacebookCatalogService.mapCondition(ItemCondition.fair),
          'used_fair');
      expect(FacebookCatalogService.mapCondition(ItemCondition.poor),
          'used_fair');
    });

    test('create request posts to the catalog products edge', () {
      final req = catalog.buildCreateItemRequest(
        catalogId: '987654321',
        item: _item(),
        imageUrls: images,
      );
      expect(req.method, 'POST');
      expect(req.path, '/987654321/products');
      expect(req.body['title'], 'IKEA LACK Side Table — White');
      expect(req.requiredPermissions,
          ['catalog_management', 'business_management']);
    });

    test('update request posts to the existing item id', () {
      final req = catalog.buildUpdateItemRequest(
        catalogItemId: '555000111',
        item: _item(),
        imageUrls: images,
      );
      expect(req.method, 'POST');
      expect(req.path, '/555000111');
      expect(req.body['retailer_id'], 'snap2sell_itm_42');
    });
  });

  group('eBay Sell payload builder', () {
    final ebay = EbayListingService();

    test('inventory item carries product, condition, quantity', () {
      final payload = ebay.buildInventoryItemPayload(
        _item(),
        imageUrls: ['https://cdn.example.com/a.jpg'],
      );
      expect(payload['condition'], 'USED_GOOD');
      expect(
        (payload['availability']
            as Map)['shipToLocationAvailability']['quantity'],
        1,
      );
      final product = payload['product'] as Map;
      expect(product['title'], 'IKEA LACK Side Table — White');
      expect(product['description'],
          'Sturdy little table. Pickup in Chilliwack.');
      expect(product['imageUrls'], ['https://cdn.example.com/a.jpg']);
      expect(product['aspects'], {
        'Category': ['Furniture'],
      });
    });

    test('condition mapping follows eBay inventory enums', () {
      expect(EbayListingService.mapCondition(ItemCondition.likeNew),
          'LIKE_NEW');
      expect(EbayListingService.mapCondition(ItemCondition.excellent),
          'USED_EXCELLENT');
      expect(
          EbayListingService.mapCondition(ItemCondition.good), 'USED_GOOD');
      expect(EbayListingService.mapCondition(ItemCondition.fair),
          'USED_ACCEPTABLE');
      expect(EbayListingService.mapCondition(ItemCondition.poor),
          'FOR_PARTS_OR_NOT_WORKING');
    });

    test('sku is stable per item', () {
      expect(EbayListingService.skuFor(_item()), 'snap2sell-itm_42');
    });

    test('offer is fixed price with account values left CONFIG_REQUIRED',
        () {
      final offer = ebay.buildOfferPayload(_item());
      expect(offer['sku'], 'snap2sell-itm_42');
      expect(offer['marketplaceId'], 'EBAY_US');
      expect(offer['format'], 'FIXED_PRICE');
      expect(offer['availableQuantity'], 1);
      expect(offer['categoryId'], EbayListingService.configRequired);
      final price = (offer['pricingSummary'] as Map)['price'] as Map;
      expect(price['value'], '12.00');
      expect(price['currency'], 'USD');
      final policies = offer['listingPolicies'] as Map;
      expect(policies['fulfillmentPolicyId'],
          EbayListingService.configRequired);
      expect(policies['paymentPolicyId'], EbayListingService.configRequired);
      expect(policies['returnPolicyId'], EbayListingService.configRequired);
      expect(offer['merchantLocationKey'], EbayListingService.configRequired);
    });

    test('offer accepts a resolved category id once known', () {
      final offer = ebay.buildOfferPayload(_item(), categoryId: '179753');
      expect(offer['categoryId'], '179753');
    });
  });

  group('Sell hub destinations', () {
    test('Facebook Marketplace is first and actionable via handoff', () {
      final first = SellDestination.all.first;
      expect(first.name, 'Facebook Marketplace');
      expect(first.kind, SellDestinationKind.handoff);
      expect(first.isActionable, isTrue);
      expect(first.actionLabel, 'List on Facebook Marketplace');
    });

    test('Shop and eBay are present but blocked with honest reasons', () {
      final shop = SellDestination.all
          .firstWhere((d) => d.name == 'Facebook Shop');
      final ebayD =
          SellDestination.all.firstWhere((d) => d.name == 'eBay');
      expect(shop.isActionable, isFalse);
      expect(shop.blockedReason, contains('Page + Shop'));
      expect(ebayD.isActionable, isFalse);
      expect(ebayD.blockedReason, contains('developer keyset'));
    });

    test('API-less marketplaces are greyed as coming, never actionable',
        () {
      final coming = SellDestination.all
          .where((d) => d.kind == SellDestinationKind.coming)
          .toList();
      expect(coming.map((d) => d.name),
          ['OfferUp', 'Mercari', 'Poshmark']);
      for (final d in coming) {
        expect(d.isActionable, isFalse);
        expect(d.blockedReason, contains('no public listing API'));
      }
    });
  });
}
