// Build-time configuration for store billing (Google Play today, Apple
// StoreKit through the same seam later).
//
// The owner has NOT chosen the paid tier's price or product shape yet,
// so nothing about the offer is hardcoded anywhere: product ids and
// their kinds arrive via the SNAP2SELL_PRODUCT_IDS dart-define (see
// AppConfig.billingProductIds in config.dart) and are parsed here.
// With no ids configured, billing is completely inert.

/// What a store product is, as declared by OUR build config (the store
/// itself only knows the id). The kind decides how a purchase is
/// started and whether the product can be owned and restored.
enum BillingProductKind {
  /// Bought, used up, bought again (Play: consume; StoreKit: consumable).
  consumable,

  /// Bought once, owned forever, restorable (Play: non-consumable).
  nonConsumable,

  /// Recurring subscription, owned while active, restorable.
  subscription,
}

/// One configured store product: an id plus its [BillingProductKind].
class BillingProductConfig {
  const BillingProductConfig({required this.id, required this.kind});

  final String id;
  final BillingProductKind kind;

  bool get isConsumable => kind == BillingProductKind.consumable;

  @override
  bool operator ==(Object other) =>
      other is BillingProductConfig && other.id == id && other.kind == kind;

  @override
  int get hashCode => Object.hash(id, kind);

  @override
  String toString() => 'BillingProductConfig($id, ${kind.name})';
}

/// Parses the SNAP2SELL_PRODUCT_IDS dart-define value.
///
/// Format: comma-separated entries, each `productId` or
/// `productId:kind`. Whitespace is ignored, empty entries are skipped,
/// and duplicate ids keep their first occurrence. An entry whose kind
/// suffix is missing or unrecognised defaults to
/// [BillingProductKind.nonConsumable] — store product ids never contain
/// a colon, so a colon always starts the kind suffix.
List<BillingProductConfig> parseBillingProductIds(String raw) {
  final out = <BillingProductConfig>[];
  final seen = <String>{};
  for (final entry in raw.split(',')) {
    final trimmed = entry.trim();
    if (trimmed.isEmpty) continue;
    var id = trimmed;
    var kind = BillingProductKind.nonConsumable;
    final colon = trimmed.indexOf(':');
    if (colon >= 0) {
      id = trimmed.substring(0, colon).trim();
      final kindName = trimmed.substring(colon + 1).trim();
      for (final value in BillingProductKind.values) {
        if (value.name == kindName) {
          kind = value;
          break;
        }
      }
    }
    if (id.isEmpty || !seen.add(id)) continue;
    out.add(BillingProductConfig(id: id, kind: kind));
  }
  return out;
}
