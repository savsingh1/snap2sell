import '../models/item.dart';

/// Shared contract for marketplace payload builders.
///
/// Each destination with a real API path (Facebook Commerce Catalog,
/// eBay Sell API) gets a builder that turns a Snap2Sell [Item] into that
/// platform's listing payload shape. Builders are pure and side-effect
/// free: they never make network calls. Sending the payload is a separate
/// step that needs the seller's own credentials (see docs/).
abstract interface class ListingPayloadBuilder {
  /// Human-readable destination name, e.g. "eBay".
  String get destinationName;

  /// The platform payload for [item], ready to serialize to JSON.
  Map<String, dynamic> buildPayload(Item item);
}
