import '../models/item.dart';
import 'listing_payload.dart';

/// A ready-to-send Meta Commerce Catalog API request.
///
/// Nothing in this app sends these yet — there are no Meta credentials
/// in the app by design. The request is built client-side (and unit
/// tested) so the existing Cloud Function backend can send it later,
/// holding the seller's access token server-side. See
/// docs/facebook-catalog-sync.md for the full spec.
class CatalogRequest {
  const CatalogRequest({
    required this.method,
    required this.path,
    required this.body,
    required this.requiredPermissions,
  });

  /// HTTP method, e.g. POST.
  final String method;

  /// Graph API path, e.g. /1234567890/products (catalog id interpolated).
  final String path;

  /// JSON body fields for the product item.
  final Map<String, dynamic> body;

  /// Meta permissions the sending token must carry.
  final List<String> requiredPermissions;
}

/// Builds Facebook Commerce Catalog product payloads (the business
/// route: sellers with a Facebook Page + Shop).
///
/// This is the ONLY Facebook route with a real posting API, and it
/// lists into the seller's Shop/catalog — NOT into their personal
/// Marketplace profile. The hub UI says so plainly.
class FacebookCatalogService implements ListingPayloadBuilder {
  @override
  String get destinationName => 'Facebook Shop (Catalog)';

  /// Permissions a user/system-user token needs to manage catalog items.
  static const requiredPermissions = [
    'catalog_management',
    'business_management',
  ];

  /// Maps a Snap2Sell condition grade to Meta's catalog condition values.
  static String mapCondition(ItemCondition condition) {
    switch (condition) {
      case ItemCondition.likeNew:
        return 'used_like_new';
      case ItemCondition.excellent:
        return 'used_good';
      case ItemCondition.good:
        return 'used_good';
      case ItemCondition.fair:
        return 'used_fair';
      case ItemCondition.poor:
        return 'used_fair';
    }
  }

  /// Catalog product fields for [item]. [imageUrls] must be publicly
  /// reachable hosted URLs — the Catalog API cannot read local files,
  /// so the backend hosts listing photos before sync (see spec doc).
  /// The first URL is the primary image; the rest are additional.
  Map<String, dynamic> buildProductFields(
    Item item, {
    required List<String> imageUrls,
  }) {
    if (imageUrls.isEmpty) {
      throw ArgumentError.value(
        imageUrls,
        'imageUrls',
        'Catalog items need at least one hosted image URL',
      );
    }
    return {
      // Stable per-listing id in the seller's catalog; re-syncing the
      // same listing updates the same item instead of duplicating it.
      'retailer_id': 'snap2sell_${item.id}',
      'title': item.title,
      'description': item.description,
      'availability': 'in stock',
      'condition': mapCondition(item.condition),
      // Meta catalog price format: amount + ISO currency code.
      'price': '${item.suggestedPrice.toStringAsFixed(2)} USD',
      'image_url': imageUrls.first,
      if (imageUrls.length > 1)
        'additional_image_urls': imageUrls.sublist(1),
      'brand': 'Snap2Sell seller',
    };
  }

  @override
  Map<String, dynamic> buildPayload(Item item) {
    // Interface convenience: payload without images. Real sends must go
    // through buildCreateItemRequest/buildUpdateItemRequest, which
    // enforce hosted image URLs.
    return {
      'retailer_id': 'snap2sell_${item.id}',
      'title': item.title,
      'description': item.description,
      'availability': 'in stock',
      'condition': mapCondition(item.condition),
      'price': '${item.suggestedPrice.toStringAsFixed(2)} USD',
      'brand': 'Snap2Sell seller',
    };
  }

  /// POST /{catalog-id}/products — creates the catalog item.
  CatalogRequest buildCreateItemRequest({
    required String catalogId,
    required Item item,
    required List<String> imageUrls,
  }) {
    return CatalogRequest(
      method: 'POST',
      path: '/$catalogId/products',
      body: buildProductFields(item, imageUrls: imageUrls),
      requiredPermissions: requiredPermissions,
    );
  }

  /// POST /{catalog-item-id} — updates an existing catalog item
  /// (matched by its Graph id, returned when the item was created).
  CatalogRequest buildUpdateItemRequest({
    required String catalogItemId,
    required Item item,
    required List<String> imageUrls,
  }) {
    return CatalogRequest(
      method: 'POST',
      path: '/$catalogItemId',
      body: buildProductFields(item, imageUrls: imageUrls),
      requiredPermissions: requiredPermissions,
    );
  }
}
