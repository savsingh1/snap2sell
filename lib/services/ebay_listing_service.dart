import '../models/item.dart';
import 'listing_payload.dart';

/// Builds eBay Sell Inventory API payloads from a Snap2Sell listing.
///
/// eBay's official flow is two calls: create/replace an inventory item
/// (PUT /sell/inventory/v1/inventory_item/{sku}), then create an offer
/// (POST /sell/inventory/v1/offer) and publish it. This builder produces
/// both JSON bodies; nothing is sent — sending needs the seller's eBay
/// OAuth token, which the backend will hold (see docs/ebay-setup.md).
///
/// Account-specific values eBay requires on every offer (policy ids,
/// merchant location) cannot be invented: they are emitted as
/// [configRequired] placeholders so a payload can never be mistaken for
/// send-ready before the owner connects a real eBay account.
class EbayListingService implements ListingPayloadBuilder {
  @override
  String get destinationName => 'eBay';

  /// Placeholder for values only a connected eBay account can supply.
  static const configRequired = 'CONFIG_REQUIRED';

  /// Maps a Snap2Sell condition grade to eBay's inventory condition enum.
  static String mapCondition(ItemCondition condition) {
    switch (condition) {
      case ItemCondition.likeNew:
        return 'LIKE_NEW';
      case ItemCondition.excellent:
        return 'USED_EXCELLENT';
      case ItemCondition.good:
        return 'USED_GOOD';
      case ItemCondition.fair:
        return 'USED_ACCEPTABLE';
      case ItemCondition.poor:
        return 'FOR_PARTS_OR_NOT_WORKING';
    }
  }

  /// The SKU Snap2Sell assigns a listing on eBay (stable per item, so
  /// re-syncing updates the same inventory item).
  static String skuFor(Item item) => 'snap2sell-${item.id}';

  /// Inventory item body (PUT /inventory_item/{sku}).
  ///
  /// [imageUrls] must be hosted URLs (eBay EPS or seller hosting) —
  /// eBay cannot read local files.
  Map<String, dynamic> buildInventoryItemPayload(
    Item item, {
    required List<String> imageUrls,
  }) {
    return {
      'availability': {
        'shipToLocationAvailability': {'quantity': 1},
      },
      'condition': mapCondition(item.condition),
      'product': {
        'title': item.title,
        'description': item.description,
        'imageUrls': imageUrls,
        'aspects': {
          'Category': [item.category],
        },
      },
    };
  }

  @override
  Map<String, dynamic> buildPayload(Item item) =>
      buildInventoryItemPayload(item, imageUrls: const []);

  /// Offer body (POST /offer). [categoryId] is eBay's leaf category for
  /// the item — resolved via the Taxonomy API once an account is
  /// connected; until then it stays [configRequired].
  Map<String, dynamic> buildOfferPayload(
    Item item, {
    String categoryId = configRequired,
    String marketplaceId = 'EBAY_US',
  }) {
    return {
      'sku': skuFor(item),
      'marketplaceId': marketplaceId,
      'format': 'FIXED_PRICE',
      'availableQuantity': 1,
      'categoryId': categoryId,
      'listingDescription': item.description,
      'pricingSummary': {
        'price': {
          'value': item.suggestedPrice.toStringAsFixed(2),
          'currency': 'USD',
        },
      },
      'listingPolicies': {
        'fulfillmentPolicyId': configRequired,
        'paymentPolicyId': configRequired,
        'returnPolicyId': configRequired,
      },
      'merchantLocationKey': configRequired,
    };
  }
}
