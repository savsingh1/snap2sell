import 'package:in_app_purchase/in_app_purchase.dart';

import 'billing_config.dart';
import 'billing_service.dart';

/// Production [BillingStoreGateway] backed by the official
/// in_app_purchase plugin, which wraps Google Play Billing on Android
/// and StoreKit on Apple platforms behind one API.
///
/// This is the ONLY billing file that knows plugin types; everything
/// above it works with the platform-neutral shapes in
/// billing_service.dart, so a future store-specific gateway can be
/// swapped in without touching [BillingService].
class InAppPurchaseGateway implements BillingStoreGateway {
  InAppPurchaseGateway({InAppPurchase? store})
      : _store = store ?? InAppPurchase.instance;

  final InAppPurchase _store;

  /// Product details from the last query, needed to start purchases.
  final Map<String, ProductDetails> _detailsById = {};

  /// Original purchases by id, needed to complete (acknowledge) them.
  final Map<String, PurchaseDetails> _purchasesById = {};

  @override
  Future<bool> isAvailable() => _store.isAvailable();

  @override
  Stream<List<StorePurchase>> get purchaseUpdates =>
      _store.purchaseStream.map(
        (purchases) => purchases.map(_mapPurchase).toList(),
      );

  @override
  Future<StoreProductCatalog> queryProducts(
    List<BillingProductConfig> configs,
  ) async {
    final ids = configs.map((c) => c.id).toSet();
    final response = await _store.queryProductDetails(ids);
    if (response.error != null) {
      throw StateError('Store product query failed: ${response.error!.code}');
    }
    _detailsById.addAll({
      for (final d in response.productDetails) d.id: d,
    });
    final kindById = {for (final c in configs) c.id: c.kind};
    final byId = {for (final d in response.productDetails) d.id: d};
    return StoreProductCatalog(
      // Configuration order, not store order, so the paywall lists
      // products the way the owner configured them.
      products: [
        for (final c in configs)
          if (byId.containsKey(c.id))
            StoreProduct(
              id: c.id,
              kind: kindById[c.id] ?? BillingProductKind.nonConsumable,
              title: byId[c.id]!.title,
              description: byId[c.id]!.description,
              price: byId[c.id]!.price,
              currencyCode: byId[c.id]!.currencyCode,
            ),
      ],
      notFoundIds: response.notFoundIDs,
    );
  }

  @override
  Future<bool> buy(StoreProduct product) async {
    final details = _detailsById[product.id];
    if (details == null) return false;
    final param = PurchaseParam(productDetails: details);
    // Subscriptions and non-consumables both start through
    // buyNonConsumable in the plugin; consumables are consumed after
    // purchase (autoConsume) so they can be bought again.
    return product.kind == BillingProductKind.consumable
        ? _store.buyConsumable(purchaseParam: param)
        : _store.buyNonConsumable(purchaseParam: param);
  }

  @override
  Future<void> restorePurchases() => _store.restorePurchases();

  @override
  Future<void> completePurchase(StorePurchase purchase) async {
    final original = _purchasesById[purchase.purchaseId];
    if (original != null && original.pendingCompletePurchase) {
      await _store.completePurchase(original);
    }
  }

  StorePurchase _mapPurchase(PurchaseDetails purchase) {
    if (purchase.purchaseID != null) {
      _purchasesById[purchase.purchaseID!] = purchase;
    }
    return StorePurchase(
      productId: purchase.productID,
      purchaseId: purchase.purchaseID,
      status: switch (purchase.status) {
        PurchaseStatus.pending => StorePurchaseStatus.pending,
        PurchaseStatus.purchased => StorePurchaseStatus.purchased,
        PurchaseStatus.restored => StorePurchaseStatus.restored,
        PurchaseStatus.error => StorePurchaseStatus.error,
        PurchaseStatus.canceled => StorePurchaseStatus.canceled,
      },
      // Prefer the server-side token (Play purchase token / Apple
      // receipt) — that is what a verification server consumes.
      verificationData:
          purchase.verificationData.serverVerificationData.isNotEmpty
              ? purchase.verificationData.serverVerificationData
              : purchase.verificationData.localVerificationData,
      errorMessage: purchase.error?.message,
      pendingComplete: purchase.pendingCompletePurchase,
    );
  }
}
