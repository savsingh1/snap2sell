import 'dart:async';

import 'package:flutter/foundation.dart';

import 'billing_config.dart';
import 'config.dart';
import 'in_app_purchase_gateway.dart';

/// A product as returned by the store, in Snap2Sell's own
/// platform-neutral shape. The billing layer never leaks plugin types,
/// so the same service serves Google Play today and Apple StoreKit
/// later — only the [BillingStoreGateway] implementation differs.
///
/// [price] is the store's own formatted price string for the user's
/// locale. The app never invents or overrides prices: if the store did
/// not return it, it is not shown.
class StoreProduct {
  const StoreProduct({
    required this.id,
    required this.kind,
    required this.title,
    required this.description,
    required this.price,
    required this.currencyCode,
  });

  final String id;
  final BillingProductKind kind;
  final String title;
  final String description;
  final String price;
  final String currencyCode;
}

/// Result of asking the store about the configured products.
class StoreProductCatalog {
  const StoreProductCatalog({
    required this.products,
    required this.notFoundIds,
  });

  /// Products the store knows, in configuration order.
  final List<StoreProduct> products;

  /// Configured ids the store has no product for (not created in the
  /// store console yet, or not active). Surfaced honestly in the UI —
  /// never silently treated as purchasable.
  final List<String> notFoundIds;
}

/// Status of a single purchase update from the store.
enum StorePurchaseStatus { pending, purchased, restored, error, canceled }

/// One purchase, in platform-neutral shape.
class StorePurchase {
  const StorePurchase({
    required this.productId,
    required this.status,
    this.purchaseId,
    this.verificationData = '',
    this.errorMessage,
    this.pendingComplete = false,
  });

  final String productId;
  final StorePurchaseStatus status;

  /// Store-side purchase/order id, when the store issued one.
  final String? purchaseId;

  /// Opaque receipt/token blob from the store. This is what a
  /// verification server checks — see [PurchaseVerifier]. It is never
  /// proof of anything on its own.
  final String verificationData;

  /// User-readable failure detail when [status] is
  /// [StorePurchaseStatus.error].
  final String? errorMessage;

  /// True when the store still needs [BillingStoreGateway
  /// .completePurchase] called for this purchase (Play acknowledgement /
  /// StoreKit finish).
  final bool pendingComplete;
}

/// The seam between [BillingService] and a real store.
///
/// The production implementation is [InAppPurchaseGateway], backed by
/// the official in_app_purchase plugin (Google Play Billing + Apple
/// StoreKit behind one API). Tests substitute a fake — no real store
/// calls ever happen in tests.
abstract interface class BillingStoreGateway {
  /// True when the device can reach a store that sells our products.
  Future<bool> isAvailable();

  /// Purchase updates (buys, restores, pending, errors) from the store.
  Stream<List<StorePurchase>> get purchaseUpdates;

  /// Asks the store about the configured products.
  Future<StoreProductCatalog> queryProducts(
    List<BillingProductConfig> configs,
  );

  /// Starts the store's purchase flow for [product]. Returns true when
  /// the flow was started; the outcome arrives on [purchaseUpdates].
  Future<bool> buy(StoreProduct product);

  /// Asks the store to re-deliver previous purchases; results arrive on
  /// [purchaseUpdates] with status [StorePurchaseStatus.restored].
  Future<void> restorePurchases();

  /// Tells the store a delivered purchase has been processed
  /// (acknowledgement). This is store bookkeeping only — it is NOT
  /// receipt verification (see [PurchaseVerifier]).
  Future<void> completePurchase(StorePurchase purchase);
}

/// Defers creating the real gateway until the first store call.
///
/// This matters: the in_app_purchase plugin starts a store connection
/// when its instance is created, so merely constructing
/// [InAppPurchaseGateway] in an unconfigured build would spin up Play
/// Billing / StoreKit machinery the app never asked for (and, in
/// tests, throws channel errors). With this wrapper, a build with no
/// product ids configured never constructs the store layer at all —
/// [BillingService.initialise] settles into its not-configured state
/// before any gateway member is touched.
class LazyBillingGateway implements BillingStoreGateway {
  LazyBillingGateway(this._create);

  final BillingStoreGateway Function() _create;
  BillingStoreGateway? _inner;

  BillingStoreGateway get _gateway => _inner ??= _create();

  @override
  Future<bool> isAvailable() => _gateway.isAvailable();

  @override
  Stream<List<StorePurchase>> get purchaseUpdates => _gateway.purchaseUpdates;

  @override
  Future<StoreProductCatalog> queryProducts(
    List<BillingProductConfig> configs,
  ) =>
      _gateway.queryProducts(configs);

  @override
  Future<bool> buy(StoreProduct product) => _gateway.buy(product);

  @override
  Future<void> restorePurchases() => _gateway.restorePurchases();

  @override
  Future<void> completePurchase(StorePurchase purchase) =>
      _gateway.completePurchase(purchase);
}

/// Outcome of checking a purchase with a verification authority.
class PurchaseVerification {
  const PurchaseVerification._(this.isVerified, this.reason);

  const PurchaseVerification.verified()
      : this._(true, 'Verified by the verification server.');

  const PurchaseVerification.unverified(String reason)
      : this._(false, reason);

  final bool isVerified;
  final String reason;
}

/// Verifies store purchases before an entitlement is treated as proven.
///
/// TODO(store-billing): there is NO verification backend yet. Before a
/// paid tier is switched on for real users, implement this against a
/// Snap2Sell backend endpoint that validates the receipt/token with
/// Google Play (Purchases API) / Apple (App Store Server API) and
/// returns the verdict. Until then the app ships
/// [UnverifiedPurchaseVerifier], which verifies NOTHING — see
/// docs/store-billing.md.
abstract interface class PurchaseVerifier {
  Future<PurchaseVerification> verify(StorePurchase purchase);
}

/// Placeholder verifier: performs NO verification and says so.
///
/// Purchases checked by this verifier are recorded by [BillingService]
/// as owned on this device but UNVERIFIED
/// ([BillingService.hasVerifiedEntitlement] stays false). Nothing in
/// the app may gate a paid feature on an unverified entitlement.
class UnverifiedPurchaseVerifier implements PurchaseVerifier {
  const UnverifiedPurchaseVerifier();

  static const String reason =
      'Server verification is not set up yet, so this purchase cannot '
      'be confirmed. It is recorded on this device only.';

  @override
  Future<PurchaseVerification> verify(StorePurchase purchase) async =>
      const PurchaseVerification.unverified(reason);
}

/// Lifecycle of the billing layer.
enum BillingServiceState {
  /// No product ids in the build config. The gateway is never touched:
  /// no store queries, no purchase UI, no behaviour change.
  notConfigured,

  /// Talking to the store (availability check / product query).
  initialising,

  /// Products loaded; purchases can be started and restored.
  ready,

  /// The store cannot be reached on this device (e.g. no Play Store).
  storeUnavailable,

  /// Initialisation failed; [BillingService.lastError] has the detail.
  error,
}

/// Store billing for the optional paid tier.
///
/// Driven entirely by build config: with no product ids configured
/// (the default build) [initialise] settles into
/// [BillingServiceState.notConfigured] without touching the store, and
/// the app is exactly the free app. No prices, tier names, or feature
/// gates live here — products, prices, and copy all come from the
/// store at runtime once the owner configures them
/// (docs/store-billing.md).
class BillingService extends ChangeNotifier {
  BillingService({
    required List<BillingProductConfig> products,
    required BillingStoreGateway gateway,
    PurchaseVerifier verifier = const UnverifiedPurchaseVerifier(),
  })  : _configs = List<BillingProductConfig>.unmodifiable(products),
        _gateway = gateway,
        _verifier = verifier;

  /// Production wiring: config from [AppConfig], the real store gateway
  /// behind a [LazyBillingGateway] so an unconfigured build never
  /// constructs the store layer.
  factory BillingService.fromAppConfig() => BillingService(
        products: parseBillingProductIds(AppConfig.billingProductIds),
        gateway: LazyBillingGateway(() => InAppPurchaseGateway()),
      );

  final List<BillingProductConfig> _configs;
  final BillingStoreGateway _gateway;
  final PurchaseVerifier _verifier;

  StreamSubscription<List<StorePurchase>>? _subscription;

  BillingServiceState _state = BillingServiceState.notConfigured;
  List<StoreProduct> _products = const [];
  List<String> _notFoundIds = const [];
  final Set<String> _ownedProductIds = <String>{};
  final Set<String> _verifiedProductIds = <String>{};
  String? _pendingProductId;
  String? _lastError;

  /// True when at least one product id was configured at build time.
  bool get isConfigured => _configs.isNotEmpty;

  BillingServiceState get state => _state;

  /// Products the store returned, in configuration order.
  List<StoreProduct> get products => List<StoreProduct>.unmodifiable(_products);

  /// Configured ids the store does not know (see [StoreProductCatalog]).
  List<String> get notFoundProductIds => List<String>.unmodifiable(_notFoundIds);

  /// Products the store says this user owns (bought or restored),
  /// recorded client-side. See [hasVerifiedEntitlement] for the trust
  /// distinction — ownership alone is not proof.
  Set<String> get ownedProductIds => Set<String>.unmodifiable(_ownedProductIds);

  bool isOwned(String productId) => _ownedProductIds.contains(productId);

  /// Any entitlement at all (client-side record only).
  bool get hasEntitlement => _ownedProductIds.isNotEmpty;

  /// True only when at least one owned purchase was confirmed by the
  /// [PurchaseVerifier]. With the shipped [UnverifiedPurchaseVerifier]
  /// this is always false — by design, until a verification backend
  /// exists. Paid features must gate on THIS, never on [hasEntitlement].
  bool get hasVerifiedEntitlement => _verifiedProductIds.isNotEmpty;

  /// Product id with a purchase currently in flight, if any.
  String? get pendingProductId => _pendingProductId;

  /// Last user-readable billing error, if any.
  String? get lastError => _lastError;

  /// Connects to the store and loads the configured products.
  ///
  /// When billing is not configured this returns immediately in the
  /// [BillingServiceState.notConfigured] state and the gateway is never
  /// touched — no store queries happen in the default build. Safe to
  /// call again after an error or unavailability to retry.
  Future<void> initialise() async {
    if (!isConfigured) {
      _state = BillingServiceState.notConfigured;
      notifyListeners();
      return;
    }
    if (_state == BillingServiceState.initialising ||
        _state == BillingServiceState.ready) {
      return;
    }
    _state = BillingServiceState.initialising;
    _lastError = null;
    notifyListeners();

    _subscription ??= _gateway.purchaseUpdates.listen(
      _onPurchases,
      onError: (Object e) {
        _lastError = 'The store sent an update we could not read. '
            'If a purchase seems stuck, try Restore Purchases.';
        notifyListeners();
      },
    );

    try {
      if (!await _gateway.isAvailable()) {
        _state = BillingServiceState.storeUnavailable;
        notifyListeners();
        return;
      }
      final catalog = await _gateway.queryProducts(_configs);
      _products = catalog.products;
      _notFoundIds = catalog.notFoundIds;
      _state = BillingServiceState.ready;
    } catch (_) {
      _state = BillingServiceState.error;
      _lastError = 'We could not reach the store to load purchases. '
          'Check your connection and try again.';
    }
    notifyListeners();
  }

  /// Starts the store purchase flow for [productId]. The result (owned,
  /// error, cancelled) arrives asynchronously via the purchase stream.
  /// Returns false without touching the store when the product is
  /// unknown or billing is not ready.
  Future<bool> buy(String productId) async {
    if (_state != BillingServiceState.ready) return false;
    StoreProduct? product;
    for (final p in _products) {
      if (p.id == productId) {
        product = p;
        break;
      }
    }
    if (product == null) return false;
    _lastError = null;
    notifyListeners();
    final started = await _gateway.buy(product);
    if (!started) {
      _lastError = 'The store could not start that purchase.';
      notifyListeners();
    }
    return started;
  }

  /// Asks the store to re-deliver previous purchases. Results arrive
  /// via the purchase stream. No-op when billing is not configured.
  Future<void> restorePurchases() async {
    if (!isConfigured) return;
    await _gateway.restorePurchases();
  }

  Future<void> _onPurchases(List<StorePurchase> purchases) async {
    for (final purchase in purchases) {
      switch (purchase.status) {
        case StorePurchaseStatus.pending:
          _pendingProductId = purchase.productId;
        case StorePurchaseStatus.purchased:
        case StorePurchaseStatus.restored:
          _pendingProductId = null;
          _ownedProductIds.add(purchase.productId);
          final verification = await _verifier.verify(purchase);
          if (verification.isVerified) {
            _verifiedProductIds.add(purchase.productId);
          }
          // Store bookkeeping: acknowledge delivery so the store stops
          // re-delivering (and, on Play, does not auto-refund). This is
          // NOT verification — the entitlement above stays unverified
          // until a real [PurchaseVerifier] confirms it.
          if (purchase.pendingComplete) {
            await _gateway.completePurchase(purchase);
          }
        case StorePurchaseStatus.error:
          _pendingProductId = null;
          _lastError = purchase.errorMessage ??
              'That purchase did not go through. No charge was made '
                  'by Snap2Sell — if the store shows a charge, contact '
                  'the store.';
        case StorePurchaseStatus.canceled:
          _pendingProductId = null;
      }
    }
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel() ?? Future<void>.value());
    super.dispose();
  }
}
